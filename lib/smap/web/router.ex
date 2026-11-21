defmodule Smap.Web.Router do
  @moduledoc """
  Local Web UI router (Bandit + Plug + SSE).

  Serves the resilient chat core UI and the fault-isolated app slot.
  """

  use Plug.Router

  alias Smap.AppSpace.Manager
  alias Smap.Chat.Session
  alias Smap.Web.AppSlot

  plug(:match)
  plug(:dispatch)

  get "/" do
    title =
      case Manager.current() do
        %{meta: %{name: name}} -> "Smap - #{AppSlot.escape_html(name)}"
        _ -> "Smap"
      end

    html = render_shell(title, AppSlot.safe_render())

    conn
    |> put_resp_content_type("text/html", "utf-8")
    |> send_resp(200, html)
  end

  get "/api/chat" do
    send_json(conn, 200, %{messages: Session.messages()})
  end

  post "/api/chat" do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, %{"content" => content}} <- decode_json(body),
         true <- is_binary(content) and String.trim(content) != "" do
      {:ok, result} = Session.send_message(String.trim(content))
      send_json(conn, 200, result)
    else
      _ ->
        send_json(conn, 400, %{error: "content must be a non-empty string"})
    end
  end

  get "/api/app/view" do
    conn
    |> put_resp_content_type("text/html", "utf-8")
    |> send_resp(200, AppSlot.safe_render())
  end

  match "/app/*path" do
    conn = Plug.Conn.fetch_query_params(conn)
    {:ok, body, conn} = read_body(conn)
    params = merge_params(conn.query_params, body)

    case Manager.handle_request(conn.method, path, params) do
      {:ok, status, headers, resp_body} ->
        conn =
          Enum.reduce(headers, conn, fn {k, v}, acc ->
            put_resp_header(acc, String.downcase(k), v)
          end)

        send_resp(conn, status, resp_body)

      {:file, file_path, content_type} ->
        if File.regular?(file_path) do
          conn
          |> put_resp_content_type(content_type)
          |> send_file(200, file_path)
        else
          send_json(conn, 404, %{error: "file_not_found"})
        end

      {:error, :no_app} ->
        send_json(conn, 404, %{error: "no_app_loaded"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/events" do
    :ok = Session.subscribe()

    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_content_type("text/event-stream", "utf-8")
      |> send_chunked(200)

    sse_loop(conn)
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp sse_loop(conn) do
    receive do
      {:smap_event, event, payload} ->
        data = :json.encode(payload) |> IO.iodata_to_binary()
        frame = "event: #{event}\ndata: #{data}\n\n"

        case chunk(conn, frame) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    after
      25_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp merge_params(query_params, "") when is_map(query_params), do: query_params

  defp merge_params(query_params, body) when is_map(query_params) and is_binary(body) do
    case decode_json(body) do
      {:ok, %{} = json_map} -> Map.merge(query_params, json_map)
      _ -> Map.put(query_params, "_raw_body", body)
    end
  end

  defp decode_json(body) do
    try do
      {:ok, :json.decode(body)}
    rescue
      _ -> {:error, :invalid_json}
    end
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json", "utf-8")
    |> send_resp(status, :json.encode(data) |> IO.iodata_to_binary())
  end

  defp render_shell(title, initial_app_html) do
    """
    <!DOCTYPE html>
    <html lang="ja">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>#{title}</title>
      <style>
        * { box-sizing: border-box; }
        body {
          margin: 0;
          height: 100vh;
          display: flex;
          font-family: "Yu Gothic UI", "Meiryo", system-ui, -apple-system, sans-serif;
          background: #0f172a;
          color: #e2e8f0;
        }
        #chat-panel {
          width: 360px;
          min-width: 280px;
          max-width: 50vw;
          display: flex;
          flex-direction: column;
          border-right: 1px solid #334155;
          background: #1e293b;
        }
        #chat-header {
          padding: 12px 16px;
          font-weight: 600;
          border-bottom: 1px solid #334155;
          display: flex;
          justify-content: space-between;
          align-items: center;
        }
        #chat-messages {
          flex: 1;
          overflow-y: auto;
          padding: 12px;
          display: flex;
          flex-direction: column;
          gap: 8px;
        }
        .msg {
          padding: 8px 12px;
          border-radius: 8px;
          white-space: pre-wrap;
          word-break: break-word;
          line-height: 1.5;
          font-size: 14px;
        }
        .msg.user {
          align-self: flex-end;
          background: #2563eb;
          color: #ffffff;
          max-width: 85%;
        }
        .msg.assistant {
          align-self: flex-start;
          background: #334155;
          color: #f1f5f9;
          max-width: 90%;
        }
        #chat-form {
          display: flex;
          gap: 8px;
          padding: 12px;
          border-top: 1px solid #334155;
        }
        #chat-input {
          flex: 1;
          resize: none;
          padding: 8px 10px;
          border-radius: 6px;
          border: 1px solid #475569;
          background: #0f172a;
          color: #f8fafc;
          font-family: inherit;
          font-size: 14px;
        }
        #chat-send {
          padding: 8px 14px;
          border: none;
          border-radius: 6px;
          background: #3b82f6;
          color: #ffffff;
          font-weight: 600;
          cursor: pointer;
        }
        #app-slot {
          flex: 1;
          overflow: auto;
          padding: 24px;
        }
        .app-slot-placeholder {
          max-width: 640px;
          margin: 48px auto;
          padding: 24px;
          border: 1px dashed #475569;
          border-radius: 12px;
          background: #1e293b;
        }
        .app-slot-error {
          max-width: 720px;
          margin: 24px auto;
          padding: 20px;
          border: 1px solid #ef4444;
          border-radius: 10px;
          background: #450a0a;
          color: #fecaca;
        }
        .app-slot-error pre {
          overflow-x: auto;
          background: #1f2937;
          padding: 12px;
          border-radius: 6px;
        }
      </style>
    </head>
    <body>
      <aside id="chat-panel">
        <div id="chat-header">
          <span>Smap チャット核</span>
          <small id="sse-status">接続中...</small>
        </div>
        <div id="chat-messages"></div>
        <form id="chat-form">
          <textarea id="chat-input" rows="2" placeholder="指示を入力（Enterで送信 / Shift+Enterで改行）"></textarea>
          <button id="chat-send" type="submit">送信</button>
        </form>
      </aside>
      <main id="app-slot">#{initial_app_html}</main>
      <script>
        const messagesEl = document.getElementById("chat-messages");
        const inputEl = document.getElementById("chat-input");
        const formEl = document.getElementById("chat-form");
        const slotEl = document.getElementById("app-slot");
        const statusEl = document.getElementById("sse-status");
        const seenIds = new Set();

        function appendMessage(msg) {
          if (msg.id && seenIds.has(msg.id)) return;
          if (msg.id) seenIds.add(msg.id);
          const div = document.createElement("div");
          div.className = "msg " + (msg.role === "user" ? "user" : "assistant");
          div.textContent = msg.content;
          messagesEl.appendChild(div);
          messagesEl.scrollTop = messagesEl.scrollHeight;
        }

        async function loadHistory() {
          const res = await fetch("/api/chat");
          if (!res.ok) return;
          const data = await res.json();
          (data.messages || []).forEach(appendMessage);
        }

        async function refreshAppSlot() {
          const res = await fetch("/api/app/view");
          if (!res.ok) return;
          slotEl.innerHTML = await res.text();
          slotEl.querySelectorAll("script").forEach((oldScript) => {
            const s = document.createElement("script");
            Array.from(oldScript.attributes).forEach((a) => s.setAttribute(a.name, a.value));
            s.textContent = oldScript.textContent;
            oldScript.replaceWith(s);
          });
        }

        async function sendCurrentInput() {
          const content = inputEl.value.trim();
          if (!content) return;
          inputEl.value = "";
          const res = await fetch("/api/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ content })
          });
          if (res.ok) {
            const data = await res.json();
            if (data.user) appendMessage(data.user);
            if (data.assistant) appendMessage(data.assistant);
          }
        }

        formEl.addEventListener("submit", (e) => {
          e.preventDefault();
          sendCurrentInput();
        });

        inputEl.addEventListener("keydown", (e) => {
          if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
            e.preventDefault();
            sendCurrentInput();
          }
        });

        const es = new EventSource("/events");
        es.onopen = () => { statusEl.textContent = "稼働中"; };
        es.onerror = () => { statusEl.textContent = "再接続中..."; };
        es.addEventListener("chat_message", (e) => {
          appendMessage(JSON.parse(e.data));
        });
        es.addEventListener("app_updated", (e) => {
          const payload = JSON.parse(e.data || "{}");
          if (payload.title) document.title = "Smap - " + payload.title;
          refreshAppSlot();
        });

        loadHistory();
      </script>
    </body>
    </html>
    """
  end
end
