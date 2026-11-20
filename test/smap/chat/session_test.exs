defmodule Smap.Chat.SessionTest do
  use ExUnit.Case, async: false

  alias Smap.Chat.Session

  setup do
    Session.clear()

    on_exit(fn ->
      Application.delete_env(:smap, :chat_responder)
      Session.clear()
    end)

    :ok
  end

  test "stores user and assistant messages in Japanese" do
    assert Session.messages() == []

    {:ok, %{user: user_msg, assistant: assistant_msg}} =
      Session.send_message("使いやすい音楽プレイヤーになれ")

    assert user_msg.role == "user"
    assert user_msg.content == "使いやすい音楽プレイヤーになれ"
    assert assistant_msg.role == "assistant"
    assert is_binary(assistant_msg.content)
    assert byte_size(assistant_msg.content) > 0

    history = Session.messages()
    assert length(history) == 2
    assert Enum.at(history, 0).content == "使いやすい音楽プレイヤーになれ"
  end

  test "notifies subscribers on new chat messages" do
    :ok = Session.subscribe()

    {:ok, _} = Session.send_message("こんにちは")

    assert_receive {:smap_event, "chat_message", %{role: "user", content: "こんにちは"}}
    assert_receive {:smap_event, "chat_message", %{role: "assistant", content: _}}
  end

  test "keeps session alive even when responder raises" do
    pid_before = Process.whereis(Session)

    Application.put_env(:smap, :chat_responder, fn _content, _history ->
      raise "responder crash"
    end)

    {:ok, %{assistant: assistant_msg}} = Session.send_message("テスト")

    assert Process.whereis(Session) == pid_before
    assert Process.alive?(pid_before)
    assert assistant_msg.role == "assistant"
    assert assistant_msg.content =~ "エラー"
  end
end
