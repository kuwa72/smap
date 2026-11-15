defmodule AgentLab.ToolsTest do
  use ExUnit.Case

  @app :tools_test_app

  setup do
    on_exit(fn ->
      File.rm(Path.join("evolution", "#{@app}.jsonl"))
    end)

    :ok
  end

  test "spawn_agent starts a registered process visible via Registry and list_processes" do
    assert {:ok, pid} = AgentLab.Tools.spawn_agent(app: @app, agent: :worker_a)
    assert is_pid(pid)
    assert Process.alive?(pid)
    assert [{^pid, _}] = Registry.lookup(AgentLab.Registry, {@app, :worker_a})

    assert Enum.any?(AgentLab.Tools.list_processes(), fn p ->
             p.pid == pid and p.key == {@app, :worker_a}
           end)
  end

  test "spawned agent inherits the Versions mechanism and can spawn recursively" do
    {:ok, mod} =
      AgentLab.Versions.load(@app, :orchestrator, """
      defmodule Orch.V1 do
        def spawn_child do
          AgentLab.Tools.spawn_agent(app: :tools_test_app, agent: :child_b)
        end
      end
      """)

    assert {:ok, parent} = AgentLab.Tools.spawn_agent(app: @app, agent: :orchestrator)
    assert AgentLab.Agent.version(parent) == mod

    assert {:ok, {:ok, child_pid}} =
             AgentLab.Tools.delegate(parent, fn -> apply(mod, :spawn_child, []) end)

    assert Process.alive?(child_pid)
    assert [{^child_pid, _}] = Registry.lookup(AgentLab.Registry, {@app, :child_b})
  end

  test "delegate runs the function in a separate process" do
    assert {:ok, task_pid} = AgentLab.Tools.delegate(fn -> self() end)
    refute task_pid == self()
  end

  test "delegate isolates crashes and timeouts without killing the caller" do
    assert {:error, _} = AgentLab.Tools.delegate(fn -> raise "boom" end)
    assert Process.alive?(self())

    assert {:error, :timeout} =
             AgentLab.Tools.delegate(fn -> Process.sleep(:infinity) end, timeout: 50)

    assert Process.alive?(self())
  end

  test "delegate to a spawned agent keeps the agent alive on failure" do
    assert {:ok, agent} = AgentLab.Tools.spawn_agent(app: @app, agent: :resilient_c)

    assert {:error, _} = AgentLab.Tools.delegate({@app, :resilient_c}, fn -> raise "boom" end)
    assert Process.alive?(agent)
    assert {:ok, 42} = AgentLab.Tools.delegate({@app, :resilient_c}, fn -> 42 end)
  end
end
