defmodule Smap.Web.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smap.Chat.Session
  alias Smap.Web.Router

  @opts Router.init([])

  setup do
    Session.clear()

    on_exit(fn ->
      Application.delete_env(:smap, :app_renderer)
      Application.delete_env(:smap, :app_render_timeout)
      Application.delete_env(:smap, :chat_responder)
      Session.clear()
    end)

    :ok
  end

  test "GET / renders initial chat panel and app slot with UTF-8 Japanese UI" do
    conn = conn(:get, "/") |> Router.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "utf-8"
    assert conn.resp_body =~ "chat-panel"
    assert conn.resp_body =~ "app-slot"
    assert conn.resp_body =~ "isComposing"
  end

  test "POST /api/chat and GET /api/chat handle Japanese messages" do
    body = :json.encode(%{content: "音楽プレイヤーを作って"}) |> IO.iodata_to_binary()

    conn =
      conn(:post, "/api/chat", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    decoded = :json.decode(conn.resp_body)
    assert decoded["user"]["content"] == "音楽プレイヤーを作って"
    assert is_binary(decoded["assistant"]["content"])

    get_conn = conn(:get, "/api/chat") |> Router.call(@opts)
    assert get_conn.status == 200
    history = :json.decode(get_conn.resp_body)
    assert length(history["messages"]) == 2
    assert Enum.at(history["messages"], 0)["content"] == "音楽プレイヤーを作って"
  end

  test "POST /api/chat rejects empty content with 400" do
    body = :json.encode(%{content: "   "}) |> IO.iodata_to_binary()

    conn =
      conn(:post, "/api/chat", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 400
  end

  test "GET /api/app/view isolates exceptions in app renderer without breaking chat" do
    Application.put_env(:smap, :app_renderer, fn ->
      raise "broken app view"
    end)

    view_conn = conn(:get, "/api/app/view") |> Router.call(@opts)
    assert view_conn.status == 200
    assert view_conn.resp_body =~ "app-slot-error"
    assert view_conn.resp_body =~ "broken app view"

    index_conn = conn(:get, "/") |> Router.call(@opts)
    assert index_conn.status == 200
    assert index_conn.resp_body =~ "chat-panel"

    body = :json.encode(%{content: "エラーを直して"}) |> IO.iodata_to_binary()

    chat_conn =
      conn(:post, "/api/chat", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert chat_conn.status == 200
  end

  test "GET /api/app/view isolates timeouts in app renderer" do
    Application.put_env(:smap, :app_render_timeout, 50)

    Application.put_env(:smap, :app_renderer, fn ->
      Process.sleep(5_000)
      "<p>never</p>"
    end)

    view_conn = conn(:get, "/api/app/view") |> Router.call(@opts)
    assert view_conn.status == 200
    assert view_conn.resp_body =~ "app-slot-error"
    assert view_conn.resp_body =~ "timeout"
  end
end
