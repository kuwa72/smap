defmodule Smap.Web.AppSlot do
  @moduledoc """
  Fault-isolated renderer for the dynamic application slot.

  Rendering always runs inside a timeout-bounded isolated task so crashes or
  infinite loops in user-generated app views never affect the chat core or
  HTTP server.
  """

  alias AgentLab.Tools

  @default_timeout 2_000

  @doc "Default placeholder HTML shown before any app is loaded."
  @spec default_render() :: String.t()
  def default_render do
    """
    <div class="app-slot-placeholder">
      <h2>アプリ表示領域（待機中）</h2>
      <p>左のチャットから「音楽プレイヤーになれ」「メモ帳を作って」などの指示を送ると、プロセスを終了せずにこの領域が目的のアプリケーションへ変身します。</p>
    </div>
    """
  end

  @doc "Render the current app slot inside an isolated task with timeout."
  @spec safe_render() :: String.t()
  def safe_render do
    renderer = Application.get_env(:smap, :app_renderer, &__MODULE__.default_render/0)
    timeout = Application.get_env(:smap, :app_render_timeout, @default_timeout)

    case Tools.run_isolated(fn -> invoke_renderer(renderer) end, timeout) do
      {:ok, html} when is_binary(html) ->
        html

      {:ok, other} ->
        error_html("unexpected renderer return value: #{inspect(other)}")

      {:error, :timeout} ->
        error_html("render timeout (#{timeout}ms)")

      {:error, reason} ->
        error_html(format_reason(reason))
    end
  end

  @doc "Escape HTML special characters."
  @spec escape_html(String.t()) :: String.t()
  def escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp invoke_renderer(fun) when is_function(fun, 0), do: fun.()

  defp invoke_renderer(mod) when is_atom(mod) do
    if function_exported?(mod, :render, 1) do
      mod.render(%{})
    else
      default_render()
    end
  end

  defp error_html(message) do
    """
    <div class="app-slot-error">
      <h3>アプリ描画エラー（チャット核は正常稼働中）</h3>
      <p>アプリ表示領域でエラーが発生しましたが、左のチャットから修復指示を続けられます。</p>
      <pre>#{escape_html(message)}</pre>
    </div>
    """
  end

  defp format_reason({%_{} = exception, _stacktrace}), do: Exception.message(exception)
  defp format_reason(reason), do: inspect(reason)
end
