defmodule Smap.Agent.Tools do
  @moduledoc """
  Tool registry and safe executor for the embedded self-modifying AI agent.
  """

  alias Smap.AppSpace.Manager

  @max_files 200

  @doc "Tool catalog described for the LLM system prompt."
  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "read_app_code",
        description: "現在のアプリバージョン・メタ情報・ソースコード全文を取得する",
        args: %{}
      },
      %{
        name: "apply_app_update",
        description:
          "新しい Elixir モジュールソース（Smap.UserApp.*）を検証・コンパイル・スモーク確認・無停止ホットスワップする。失敗時は直前の安定版へ自動ロールバックされエラー詳細が返る",
        args: %{source: "Elixir source code string defining Smap.UserApp.*"}
      },
      %{
        name: "rollback_app",
        description: "1つ前の安定バージョンへ明示的にロールバックする",
        args: %{}
      },
      %{
        name: "inspect_runtime",
        description: "稼働中の App Space 子プロセス一覧・現行バージョン・直近エラーを取得する",
        args: %{}
      },
      %{
        name: "list_local_files",
        description: "許可されたディレクトリ配下のファイル・フォルダ一覧を取得する",
        args: %{path: "Directory path string"}
      }
    ]
  end

  @doc "Execute a named tool with map arguments."
  @spec execute(String.t(), map()) :: map()
  def execute("read_app_code", _args) do
    case Manager.current() do
      nil ->
        %{ok: true, version: nil, module: nil, meta: nil, source: nil}

      entry ->
        %{
          ok: true,
          version: entry.version,
          module: inspect(entry.module),
          meta: entry.meta,
          source: entry.source
        }
    end
  end

  def execute("apply_app_update", %{"source" => source}) when is_binary(source) do
    case Manager.deploy(source) do
      {:ok, entry} ->
        %{
          ok: true,
          version: entry.version,
          title: entry.meta.name,
          module: inspect(entry.module)
        }

      {:error, reason} ->
        %{ok: false, error: format_error(reason)}
    end
  end

  def execute("apply_app_update", _args) do
    %{ok: false, error: "missing required string argument: source"}
  end

  def execute("rollback_app", _args) do
    case Manager.rollback() do
      {:ok, entry} ->
        %{ok: true, version: entry.version, title: entry.meta.name, module: inspect(entry.module)}

      {:error, reason} ->
        %{ok: false, error: format_error(reason)}
    end
  end

  def execute("inspect_runtime", _args) do
    %{ok: true, status: Manager.status()}
  end

  def execute("list_local_files", %{"path" => path}) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      not allowed_path?(expanded) ->
        %{ok: false, error: "access denied: path is outside allowed roots"}

      not File.dir?(expanded) ->
        %{ok: false, error: "not a directory: #{expanded}"}

      true ->
        case File.ls(expanded) do
          {:ok, names} ->
            entries =
              names
              |> Enum.sort()
              |> Enum.take(@max_files)
              |> Enum.map(fn name ->
                full = Path.join(expanded, name)
                stat = File.stat(full)

                %{
                  name: name,
                  type: if(File.dir?(full), do: "dir", else: "file"),
                  size:
                    case stat do
                      {:ok, %{size: size}} -> size
                      _ -> nil
                    end
                }
              end)

            %{ok: true, path: expanded, entries: entries}

          {:error, reason} ->
            %{ok: false, error: "failed to list directory: #{inspect(reason)}"}
        end
    end
  end

  def execute("list_local_files", _args) do
    %{ok: false, error: "missing required string argument: path"}
  end

  def execute(unknown, _args) do
    %{ok: false, error: "unknown tool: #{inspect(unknown)}"}
  end

  defp allowed_path?(expanded) do
    roots = Application.get_env(:smap, :allowed_file_roots, [File.cwd!()])
    target_parts = expanded |> resolve_realpath() |> Path.split()

    Enum.any?(roots, fn root ->
      root_parts = root |> Path.expand() |> resolve_realpath() |> Path.split()
      List.starts_with?(target_parts, root_parts)
    end)
  end

  defp resolve_realpath(path) do
    path
    |> Path.split()
    |> Enum.reduce("", fn segment, acc ->
      next = if acc == "", do: segment, else: Path.join(acc, segment)

      case File.read_link(next) do
        {:ok, target} ->
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(next))
          end

        {:error, _} ->
          next
      end
    end)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
