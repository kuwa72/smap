defmodule Smap.Chat.Session do
  @moduledoc """
  Resident chat session (Core) that stores conversation history and broadcasts
  live events to subscribed UI clients (SSE).
  """

  use GenServer

  @type message :: %{
          id: pos_integer(),
          role: String.t(),
          content: String.t(),
          ts: String.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all messages in chronological order."
  @spec messages() :: [message()]
  def messages do
    GenServer.call(__MODULE__, :messages)
  end

  @doc "Append a user message, generate a reply via configured responder, and broadcast both."
  @spec send_message(String.t()) :: {:ok, %{user: message(), assistant: message()}}
  def send_message(content) when is_binary(content) do
    GenServer.call(__MODULE__, {:send_message, content}, 15_000)
  end

  @doc "Clear conversation history."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc "Subscribe the calling process to `{:smap_event, event, payload}` notifications."
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc "Broadcast a named event to all subscribed processes."
  @spec broadcast(String.t(), map()) :: :ok
  def broadcast(event, payload) when is_binary(event) and is_map(payload) do
    GenServer.cast(__MODULE__, {:broadcast, event, payload})
  end

  @impl true
  def init(_opts) do
    {:ok, %{next_id: 1, messages: [], subscribers: %{}}}
  end

  @impl true
  def handle_call(:messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | next_id: 1, messages: []}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
    end
  end

  def handle_call({:send_message, content}, _from, state) do
    user_msg = build_message(state.next_id, "user", content)
    history_with_user = state.messages ++ [user_msg]
    notify_all(state.subscribers, "chat_message", user_msg)

    reply_text = safe_respond(content, history_with_user)
    assistant_msg = build_message(state.next_id + 1, "assistant", reply_text)
    notify_all(state.subscribers, "chat_message", assistant_msg)

    new_state = %{
      state
      | next_id: state.next_id + 2,
        messages: history_with_user ++ [assistant_msg]
    }

    {:reply, {:ok, %{user: user_msg, assistant: assistant_msg}}, new_state}
  end

  @impl true
  def handle_cast({:broadcast, event, payload}, state) do
    notify_all(state.subscribers, event, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  defp build_message(id, role, content) do
    %{
      id: id,
      role: role,
      content: content,
      ts: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp notify_all(subscribers, event, payload) do
    Enum.each(Map.keys(subscribers), fn pid ->
      send(pid, {:smap_event, event, payload})
    end)
  end

  defp safe_respond(content, history) do
    responder = Application.get_env(:smap, :chat_responder, &default_responder/2)

    try do
      case responder.(content, history) do
        {:ok, text} when is_binary(text) -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end
    rescue
      e -> "応答処理でエラーが発生しました: #{Exception.message(e)}"
    catch
      kind, reason -> "応答処理でエラーが発生しました (#{kind}): #{inspect(reason)}"
    end
  end

  defp default_responder(content, _history) do
    "受け取りました: 「#{content}」（現在チャット核のみ稼働中です。自己改修ループ接続後にアプリへ反映されます）"
  end
end
