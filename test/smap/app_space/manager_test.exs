defmodule Smap.AppSpace.ManagerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Smap.AppSpace.Manager
  alias Smap.Chat.Session
  alias Smap.Web.Router

  @router_opts Router.init([])

  @v1_source """
  defmodule Smap.UserApp.CounterV1 do
    use Smap.AppSpace.Behaviour

    defmodule Store do
      use Agent
      def start_link(_), do: Agent.start_link(fn -> 1 end, name: __MODULE__)
      def get, do: Agent.get(__MODULE__, & &1)
      def inc, do: Agent.update(__MODULE__, &(&1 + 1))
    end

    @impl true
    def app_meta, do: %{name: "カウンターV1", description: "v1"}

    @impl true
    def child_specs, do: [Store]

    @impl true
    def render(_state), do: "<div id='counter-v1'>V1: \#{Store.get()}</div>"

    @impl true
    def handle_request("GET", ["count"], _params) do
      {:ok, 200, [{"content-type", "application/json"}], ~s({"version":1,"count":\#{Store.get()}})}
    end

    def handle_request("POST", ["inc"], _params) do
      Store.inc()
      {:ok, 200, [{"content-type", "application/json"}], ~s({"version":1,"count":\#{Store.get()}})}
    end
  end
  """

  @v2_source """
  defmodule Smap.UserApp.CounterV2 do
    use Smap.AppSpace.Behaviour

    defmodule Store do
      use Agent
      def start_link(_), do: Agent.start_link(fn -> 100 end, name: __MODULE__)
      def get, do: Agent.get(__MODULE__, & &1)
    end

    @impl true
    def app_meta, do: %{name: "カウンターV2", description: "v2"}

    @impl true
    def child_specs, do: [Store]

    @impl true
    def render(_state), do: "<div id='counter-v2'>V2: \#{Store.get()}</div>"

    @impl true
    def handle_request("GET", ["count"], _params) do
      {:ok, 200, [{"content-type", "application/json"}], ~s({"version":2,"count":\#{Store.get()}})}
    end
  end
  """

  setup do
    Manager.reset()
    Session.clear()

    on_exit(fn ->
      Manager.reset()
      Session.clear()
    end)

    :ok
  end

  test "hot-swaps V1 -> V2 without downtime, manages child processes, and broadcasts SSE events" do
    :ok = Session.subscribe()

    assert {:ok, v1} = Manager.deploy(@v1_source)
    assert v1.version == 1
    assert v1.meta.name == "カウンターV1"
    assert Process.whereis(Smap.UserApp.CounterV1.Store) != nil

    assert_receive {:smap_event, "app_updated", %{version: 1, title: "カウンターV1"}}

    # View and dynamic HTTP route work for V1
    view1 = conn(:get, "/api/app/view") |> Router.call(@router_opts)
    assert view1.status == 200
    assert view1.resp_body =~ "V1: 1"

    inc = conn(:post, "/app/inc") |> Router.call(@router_opts)
    assert inc.status == 200
    assert :json.decode(inc.resp_body) == %{"version" => 1, "count" => 2}

    # Hot-swap to V2
    assert {:ok, v2} = Manager.deploy(@v2_source)
    assert v2.version == 2
    assert v2.meta.name == "カウンターV2"
    assert Process.whereis(Smap.UserApp.CounterV1.Store) == nil
    assert Process.whereis(Smap.UserApp.CounterV2.Store) != nil

    assert_receive {:smap_event, "app_updated", %{version: 2, title: "カウンターV2"}}

    view2 = conn(:get, "/api/app/view") |> Router.call(@router_opts)
    assert view2.resp_body =~ "V2: 100"

    count2 = conn(:get, "/app/count") |> Router.call(@router_opts)
    assert count2.status == 200
    assert :json.decode(count2.resp_body) == %{"version" => 2, "count" => 100}
  end

  test "automatically rolls back to previous stable version on compile, render, or child crash" do
    assert {:ok, _} = Manager.deploy(@v1_source)

    # 1. Compile error
    assert {:error, _} = Manager.deploy("defmodule Smap.UserApp.Bad do\n  def x, do: +\nend")
    assert Manager.current().version == 1
    assert Process.whereis(Smap.UserApp.CounterV1.Store) != nil

    # 2. Render exception
    broken_render = """
    defmodule Smap.UserApp.BrokenRender do
      use Smap.AppSpace.Behaviour
      def render(_), do: raise("render boom")
    end
    """

    assert {:error, _} = Manager.deploy(broken_render)
    assert Manager.current().version == 1
    assert Process.whereis(Smap.UserApp.CounterV1.Store) != nil
    assert Manager.render_current() =~ "V1:"

    # 3. Child startup crash
    broken_child = """
    defmodule Smap.UserApp.BrokenChild do
      use Smap.AppSpace.Behaviour

      defmodule Crasher do
        def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
        def start_link, do: {:error, :init_failed}
      end

      def child_specs, do: [Crasher]
      def render(_), do: "<p>ok</p>"
    end
    """

    assert {:error, _} = Manager.deploy(broken_child)
    assert Manager.current().version == 1
    assert Process.whereis(Smap.UserApp.CounterV1.Store) != nil

    # 4. Invalid child_spec must not crash Manager itself
    manager_pid = Process.whereis(Manager)

    invalid_spec_app = """
    defmodule Smap.UserApp.InvalidSpec do
      use Smap.AppSpace.Behaviour
      def child_specs, do: [123]
      def render(_), do: "<p>ok</p>"
    end
    """

    assert {:error, {:child_start_failed, _}} = Manager.deploy(invalid_spec_app)
    assert Process.whereis(Manager) == manager_pid
    assert Manager.current().version == 1
    assert Process.whereis(Smap.UserApp.CounterV1.Store) != nil
  end

  test "explicit rollback switches back from V2 to V1" do
    assert {:ok, _} = Manager.deploy(@v1_source)
    assert {:ok, _} = Manager.deploy(@v2_source)
    assert Manager.current().version == 2

    assert {:ok, rolled} = Manager.rollback()
    assert rolled.version == 1
    assert Process.whereis(Smap.UserApp.CounterV2.Store) == nil
    assert Process.whereis(Smap.UserApp.CounterV1.Store) != nil
    assert Manager.render_current() =~ "V1:"
  end

  test "restores previous bytecode on failure and rollback for same-name module redeploys" do
    same_v1 = """
    defmodule Smap.UserApp.SameApp do
      use Smap.AppSpace.Behaviour
      def app_meta, do: %{name: "SameV1", description: ""}
      def render(_), do: "<p>same-v1</p>"
    end
    """

    same_broken = """
    defmodule Smap.UserApp.SameApp do
      use Smap.AppSpace.Behaviour
      def app_meta, do: %{name: "SameBroken", description: ""}
      def render(_), do: raise("broken same-name v2")
    end
    """

    same_v2 = """
    defmodule Smap.UserApp.SameApp do
      use Smap.AppSpace.Behaviour
      def app_meta, do: %{name: "SameV2", description: ""}
      def render(_), do: "<p>same-v2</p>"
    end
    """

    assert {:ok, _} = Manager.deploy(same_v1)
    assert Manager.render_current() == "<p>same-v1</p>"

    # Broken redeploy with the exact same module name must restore V1 bytecode
    assert {:error, _} = Manager.deploy(same_broken)
    assert Manager.current().version == 1
    assert Manager.render_current() == "<p>same-v1</p>"

    # Valid redeploy with the same module name, then explicit rollback back to V1
    assert {:ok, _} = Manager.deploy(same_v2)
    assert Manager.render_current() == "<p>same-v2</p>"

    assert {:ok, rolled} = Manager.rollback()
    assert rolled.version == 1
    assert Manager.render_current() == "<p>same-v1</p>"
  end
end
