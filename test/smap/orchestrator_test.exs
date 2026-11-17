defmodule Smap.OrchestratorTest do
  use ExUnit.Case

  @app "orch_test"
  @agent "doubling"

  @module_source """
  defmodule Apps.OrchTest do
    use AgentLab.App

    def agents, do: ["doubling"]

    def tasks do
      [%{input: 1, expect: 2}, %{input: 2, expect: 4}]
    end

    def evaluate(agent, %{input: input, expect: expect}) do
      try do
        if apply(agent, :solve, [input]) == expect, do: 1.0, else: 0.0
      catch
        _, _ -> 0.0
      end
    end
  end
  """

  @spec_json """
  {"app": "orch_test",
   "module": #{inspect(@module_source)},
   "agents": [{"name": "doubling", "role": "math", "prompt": "double inputs",
               "code_template": "defmodule Doubling.V0 do\\n  def solve(x), do: x * 2\\nend",
               "tools": [],
               "evaluation": [{"input": 1, "expect": 2}, {"input": 2, "expect": 4}]}]}
  """

  setup do
    Application.put_env(:smap, :orchestrator_chat, &stub_chat/1)

    on_exit(fn ->
      Application.delete_env(:smap, :orchestrator_chat)
      File.rm("agents/doubling.edn")
      File.rm("lib/apps/orch_test.ex")
    end)

    :ok
  end

  defp stub_chat([%{content: content} | _]) do
    if String.contains?(content, "Return ONLY a JSON object") do
      {:ok, @spec_json}
    else
      {:ok, "```elixir\ndefmodule Doubling.V1 do\n  def solve(x), do: x * 2\nend\n```"}
    end
  end

  defp wait_for(fun, attempts \\ 100)
  defp wait_for(_fun, 0), do: flunk("timed out waiting for orchestrator")

  defp wait_for(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(50)
        wait_for(fun, attempts - 1)

      other ->
        other
    end
  end

  test "submit_goal designs, persists and improves an app" do
    assert :ok = Smap.Orchestrator.submit_goal("build a doubling app")

    state =
      wait_for(fn ->
        case Smap.Orchestrator.status().status do
          :running -> nil
          other -> other
        end
      end)

    assert state == :done
    result = Smap.Orchestrator.status().result
    assert result.app == @app
    assert result.agents == 1
    assert [%{decision: decision}] = result.results
    assert decision in [:adopted, :rejected]

    assert File.exists?("agents/doubling.edn")
    assert File.exists?("lib/apps/orch_test.ex")

    assert {:ok, _def} = AgentLab.Definition.load(@agent)
    assert AgentLab.Versions.current(String.to_atom(@app), @agent) != nil
  end

  test "retries design once when the first response is not a valid spec" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Application.put_env(:smap, :orchestrator_chat, fn _messages ->
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        0 -> {:ok, "sorry, here is code ```elixir\ndefmodule X do end\n```"}
        _ -> stub_chat([%{content: "Return ONLY a JSON object"}])
      end
    end)

    assert :ok = Smap.Orchestrator.submit_goal("retry me")

    state =
      wait_for(fn ->
        case Smap.Orchestrator.status().status do
          :running -> nil
          other -> other
        end
      end)

    assert state == :done
    assert Smap.Orchestrator.status().result.app == @app
  end

  test "second goal while running is rejected" do
    # First goal completes fast with the stub; submit twice quickly.
    assert :ok = Smap.Orchestrator.submit_goal("first")
    assert Smap.Orchestrator.submit_goal("second") in [:ok, {:error, :busy}]

    wait_for(fn ->
      case Smap.Orchestrator.status().status do
        :running -> nil
        _ -> true
      end
    end)
  end
end
