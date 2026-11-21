defmodule Smap.Agent.LoopTest do
  use ExUnit.Case, async: false

  alias Smap.Agent.Loop
  alias Smap.AppSpace.Manager
  alias Smap.Chat.Session

  @player_v1 """
  defmodule Smap.UserApp.MusicPlayer do
    use Smap.AppSpace.Behaviour
    def app_meta, do: %{name: "音楽プレイヤー", description: "v1"}
    def render(_), do: "<div id='player'>音楽プレイヤー v1</div>"
  end
  """

  @player_v2 """
  defmodule Smap.UserApp.MusicPlayer do
    use Smap.AppSpace.Behaviour
    def app_meta, do: %{name: "音楽プレイヤー", description: "v2 with playlist"}
    def render(_), do: "<div id='player'>音楽プレイヤー v2（プレイリスト付き）</div>"
  end
  """

  setup do
    Manager.reset()
    Session.clear()

    on_exit(fn ->
      Application.delete_env(:smap, :agent_chat)
      Application.delete_env(:smap, :agent_max_steps)
      Application.delete_env(:smap, :agent_timeout)
      Manager.reset()
      Session.clear()
    end)

    :ok
  end

  test "transforms app on first prompt and iteratively extends it on follow-up prompt" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    Application.put_env(:smap, :agent_chat, fn messages ->
      step = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      send(test_pid, {:llm_messages, step, messages})

      case step do
        1 ->
          {:ok,
           :json.encode(%{
             action: "tool",
             tool: "apply_app_update",
             args: %{source: @player_v1}
           })
           |> IO.iodata_to_binary()}

        2 ->
          {:ok,
           :json.encode(%{action: "reply", message: "音楽プレイヤー v1 を作成しました。"})
           |> IO.iodata_to_binary()}

        3 ->
          {:ok,
           :json.encode(%{
             action: "tool",
             tool: "apply_app_update",
             args: %{source: @player_v2}
           })
           |> IO.iodata_to_binary()}

        4 ->
          {:ok,
           :json.encode(%{action: "reply", message: "プレイリスト機能を追加しました。"})
           |> IO.iodata_to_binary()}
      end
    end)

    # First turn via Session -> transforms into Music Player v1
    {:ok, %{assistant: reply1}} = Session.send_message("使いやすい音楽プレイヤーになれ")
    assert reply1.content =~ "音楽プレイヤー v1"
    assert Manager.current().version == 1
    assert Manager.render_current() =~ "音楽プレイヤー v1"

    # Follow-up turn -> sees existing V1 source in context and upgrades to V2
    {:ok, %{assistant: reply2}} = Session.send_message("プレイリスト機能を追加して")
    assert reply2.content =~ "プレイリスト"
    assert Manager.current().version == 2
    assert Manager.render_current() =~ "プレイリスト付き"

    assert_receive {:llm_messages, 3, turn2_msgs}
    system_prompt = Enum.find(turn2_msgs, &(&1.role == "system")).content
    assert system_prompt =~ "音楽プレイヤー v1"
  end

  test "self-corrects when first apply_app_update fails and retries with fixed code" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    broken = """
    defmodule Smap.UserApp.MusicPlayer do
      use Smap.AppSpace.Behaviour
      def render(_), do: raise("render failed")
    end
    """

    Application.put_env(:smap, :agent_chat, fn messages ->
      step = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      send(test_pid, {:step_messages, step, messages})

      case step do
        1 ->
          {:ok,
           :json.encode(%{action: "tool", tool: "apply_app_update", args: %{source: broken}})
           |> IO.iodata_to_binary()}

        2 ->
          {:ok,
           :json.encode(%{action: "tool", tool: "apply_app_update", args: %{source: @player_v1}})
           |> IO.iodata_to_binary()}

        3 ->
          {:ok,
           :json.encode(%{action: "reply", message: "エラーを修正してデプロイしました。"})
           |> IO.iodata_to_binary()}
      end
    end)

    {:ok, reply, info} = Loop.respond("音楽プレイヤーを作って", [])
    assert reply =~ "修正してデプロイ"
    assert length(info.steps) == 2
    assert Manager.current().version == 1

    # Verify the error from step 1 was fed back to the LLM on step 2
    assert_receive {:step_messages, 2, step2_msgs}
    assert Enum.any?(step2_msgs, fn m -> m.content =~ "render failed" end)
  end

  test "stops safely at max_steps without breaking existing stable version" do
    assert {:ok, _} = Manager.deploy(@player_v1)
    Application.put_env(:smap, :agent_max_steps, 2)

    Application.put_env(:smap, :agent_chat, fn _messages ->
      {:ok,
       :json.encode(%{
         action: "tool",
         tool: "apply_app_update",
         args: %{source: "defmodule Smap.UserApp.Broken do\n  def x, do: +\nend"}
       })
       |> IO.iodata_to_binary()}
    end)

    {:ok, reply, info} = Loop.respond("壊れた変更をして", [])
    assert length(info.steps) == 2
    assert reply =~ "上限"
    assert Manager.current().version == 1
    assert Manager.render_current() =~ "音楽プレイヤー v1"
  end

  test "enforces overall deadline and aborts hung LLM calls cleanly" do
    Application.put_env(:smap, :agent_chat, fn _messages ->
      Process.sleep(5_000)
      {:ok, ~s({"action":"reply","message":"late"})}
    end)

    assert {:error, :timeout} = Loop.respond("時間切れテスト", [], timeout: 80)
    assert Process.alive?(Process.whereis(Loop))
  end
end
