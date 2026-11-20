# Smap Phase 5 アーキテクチャ設計: 自己進化型チャット常駐アプリ

## 1. 概要・到達点

単一バイナリをダウンロードして実行すると、そのプロセスと対話できるチャット GUI が即座に起動する。
ユーザーから自然言語で指示（例: 「使いやすい音楽プレイヤーになれ」「プレイリスト機能を追加して」）を与えると、**プロセスを終了させずに自分自身の機能と画面表示を書き換え・拡張し続け、目的のアプリケーションへ成長する**。

同一マシン上に複数の smap インスタンス（例: 表計算用 smap、音楽プレイヤー用 smap）を同時に存在・起動できることを前提とする。

---

## 2. Supervision Tree 分離（落ちない核 vs 動的アプリ空間）

生成コードのコンパイル失敗・実行時例外・クラッシュがチャット窓口や AI エージェント機能へ波及しないよう、Supervision Tree を「核（Core）」と「変身領域（App Space）」に分離する。

```text
Smap.Supervisor (:one_for_one)
├── [既存 AgentLab 基盤]
│   ├── AgentLab.Versions
│   ├── AgentLab.Blackboard
│   ├── AgentLab.Registry
│   ├── AgentLab.Agents (DynamicSupervisor)
│   ├── AgentLab.TaskSupervisor
│   ├── AgentLab.Transport
│   └── Smap.Orchestrator
├── [落ちない核 (Core)]
│   ├── Smap.Instance (インスタンス設定: data_dir / port / instance_name)
│   ├── Smap.Chat.Session (会話履歴・SSE 購読管理)
│   ├── Smap.Agent.Loop (内包 AI エージェント・Tool Use 自己改修ループ)
│   └── Smap.Web.Endpoint (Bandit + Plug: 127.0.0.1:<assigned_port>)
└── [変身領域 (App Space)]
    ├── Smap.AppSpace.Supervisor (DynamicSupervisor: 生成アプリ専用プロセス群)
    └── Smap.AppSpace.Manager (バージョン管理・コンパイル・ホットスワップ・自動ロールバック)
```

### 4 層の障害隔離・安全ガード

1. **Supervision Tree 分離**: App Space 配下のプロセスがクラッシュしても Core（Web サーバー・チャット・AI エージェント）は継続稼働する。
2. **タイムアウト付き別プロセス実行**: 生成コードのコンパイル、`render/1`、`/app/*` リクエスト処理はすべて `Task.Supervisor.async_nolink`（タイムアウト付き）で実行し、例外や無限ループで呼び出し元を落とさない。
3. **ステージング＆自動ロールバック**: 新コードの適用は「AST/名前空間検証 → 別プロセスコンパイル → スモークチェック（起動・描画） → ポインタ切替」の順で行い、失敗時は現行バージョンを維持してエラー詳細を AI エージェントへ返す。
4. **BEAM 固有リスクのガード**:
   - **名前空間の強制**: 生成モジュール名は `Smap.UserApp.*`（例: `Smap.UserApp.V001`）のみ許可し、核モジュール（`Smap.Web.*`, `Smap.Agent.*`, `Smap.AppSpace.*`, `AgentLab.*` 等）の上書きをロード前に拒否する。
   - **危険呼び出しの AST 拒否**: VM 全体を終了・破壊する呼び出し（`System.halt/0,1`, `:init.stop/0,1`, `:erlang.halt/0,1,2`, `:code.load_binary/3` の直接呼び出し等）をコンパイル前に AST 検査で拒否する。

---

## 3. UI 方式（Windows 日本語 GUI 対応）

Windows を含むデスクトップ環境で日本語 IME 入出力・フォント描画・音声/メディア再生（`<audio>` / Web Audio / Canvas 等）を無理なく実現するため、**ローカル Web UI** を採用する。

- **サーバー**: `Bandit` + `Plug`（純粋 Elixir/OTP 構成、ネイティブ GUI/NIF 依存なし）。`127.0.0.1` にのみバインドし外部公開しない。
- **ウィンドウ起動**: 起動時に OS に応じて GUI を自動オープンする（環境変数/引数で無効化可能）。
  - Windows: `msedge --app=http://127.0.0.1:<port>`（独立したアプリ風ウィンドウ。Edge 不在時は既定ブラウザにフォールバック）
  - Linux / macOS: `xdg-open` / `open`（または標準出力へ URL 表示）
- **画面構成**:
  - **チャットパネル（核）**: 常設（折りたたみ/リサイズ可能）。日本語 IME 対応。アプリ領域がエラーを起こしても操作継続可能。
  - **アプリ表示スロット（変身領域）**: 現行の `Smap.UserApp.*` が描画する領域。`/app/*` エンドポイントと通信して状態操作やファイル配信を行う。
- **ライブ更新**: `Smap.AppSpace.Manager` がホットスワップに成功すると、SSE（Server-Sent Events: `/events`）経由で `app_updated` イベントを配信し、チャット履歴を保持したままアプリ表示スロットとウィンドウタイトルを無停止更新する。

---

## 4. 生成アプリ規約（`Smap.AppSpace.Behaviour`）

App Space にロードされるアプリモジュールは以下のコールバックを実装する。

```elixir
@callback app_meta() :: %{name: String.t(), description: String.t()}
@callback child_specs() :: [Supervisor.child_spec()]
@callback render(state :: map()) :: String.t()
@callback handle_request(method :: String.t(), path :: [String.t()], params :: map()) ::
            {:ok, status :: pos_integer(), headers :: [{String.t(), String.t()}], body :: iodata()}
            | {:file, Path.t(), content_type :: String.t()}
```

- `child_specs/0`: 状態管理用の GenServer 等が必要な場合に定義し、`Smap.AppSpace.Supervisor` 配下へ起動する。バージョン切替時は旧子プロセスを安全に停止して新子プロセスを起動する。
- `render/1`: アプリ表示スロットへ埋め込む HTML/CSS/JS を返す。
- `handle_request/3`: `/app/*` への HTTP リクエスト（API 呼び出しやローカル音声ファイルのストリーミング配信など）を処理する。

---

## 5. 内包 AI エージェントのツール仕様（Tool Use 継続改修ループ）

`Smap.Agent.Loop` はユーザーとの会話履歴・現行バージョンソース・稼働状態・直近エラーログをコンテキストとして保持し、以下のツールを用いて段階的にアプリを成長させる。

| ツール名 | 役割 |
|---|---|
| `read_app_code` | 現行バージョンのソースコードとバージョン一覧を取得 |
| `apply_app_update` | 新ソースを検証・コンパイル・スモーク確認・ホットスワップ適用（失敗時は自動ロールバックしエラー詳細を返却） |
| `rollback_app` | 直前または指定の安定バージョンへ明示的にロールバック |
| `inspect_runtime` | App Space 配下の稼働プロセス一覧・直近エラーログ・アプリメタ情報を取得 |
| `list_local_files` | ユーザーが許可したディレクトリ配下のファイル一覧・メタ情報を取得（例: 音楽フォルダ探索） |
| `read_app_storage` / `write_app_storage` | `Smap.AppSpace.Storage` 経由でアプリ固有データを読み書き |

- コンパイルまたはスモーク確認に失敗した場合、エラーメッセージをエージェントへフィードバックし、上限回数（既定 3 回）まで自律的に自己修正を試みる。

---

## 6. 永続化・再起動復元・複数インスタンス共存

### 複数インスタンス共存（衝突防止）

1 台の PC 上で複数用途の smap（表計算用、音楽プレイヤー用など）を同時に存在・起動できるよう、以下を標準仕様とする。

1. **インスタンス別データディレクトリ**:
   - 優先順位: `--data-dir` 引数 > 環境変数 `SMAP_DATA_DIR` > **実行ファイルと同階層の `<exe_basename>.smap-data/`**（開発時 `mix` 実行時は `./.smap-data/`）。
   - バイナリを別フォルダへ複製またはリネームするだけで完全に独立した成長データを持つ。
2. **エフェメラルポート自動割り当て**:
   - 既定ポートは `0`（OS の空きポート自動割り当て）。実際にバインドされたポートで GUI を開く（必要時のみ `SMAP_PORT` / `--port` で固定可能）。
3. **ブラウザストレージ非依存**:
   - ポート変更によりブラウザのオリジンが変わってもデータが消えないよう、永続データは必ず Elixir 側の `Smap.AppSpace.Storage`（データディレクトリ配下）に保存する。
   - ブラウザのウィンドウタイトルは `app_meta().name` を反映して複数ウィンドウを識別可能にする。

### データディレクトリ構造

```text
<data_dir>/
├── manifest.json         # 現行安定バージョン番号・バージョン履歴・インスタンス設定
├── versions/
│   ├── v001.ex           # 各バージョンの Elixir ソース
│   └── v002.ex
├── chat_history.jsonl    # チャット会話履歴
└── data/                 # Smap.AppSpace.Storage が管理するアプリ固有データ（JSON/KV）
```

### 起動時の復元フロー

1. Core（Web サーバー・チャット・AI エージェント）を必ず先に起動する。
2. `manifest.json` が存在する場合、現行バージョンの `.ex` をコンパイル・ロードして `AppSpace` を起動する。
3. ロードや起動に失敗した場合は直前の安定バージョンへ遡って復元を試み、すべて失敗しても初期チャット状態のまま起動して修復可能な状態を維持する。

---

## 7. 単一バイナリ配布

- `mix release` および **Burrito** を用いて Windows / Linux 向けの単一実行バイナリを生成する。
- `mix` コマンドやソースツリーが存在しない実行環境でも、Elixir ランタイム内蔵の `Code.compile_string/1` + `:code.load_binary/3` によって自己書き換えと `<data_dir>` への永続化が完結する。
