defmodule Apps.FunctionOptimizerTest do
  use ExUnit.Case

  alias Apps.FunctionOptimizer
  alias AgentLab.{App, Versions}

  @app :function_optimizer
  @agent "function_optimizer"

  setup do
    :ets.delete(:agentlab_versions, {@app, @agent})
    :ets.delete(:agentlab_scores, {@app, @agent})

    on_exit(fn -> File.rm(Path.join("evolution", "function_optimizer.jsonl")) end)

    :ok
  end

  defmodule DummyApp do
    use AgentLab.App
  end

  test "use AgentLab.App provides default no-op callbacks" do
    assert DummyApp.agents() == []
    assert DummyApp.tasks() == []
    assert DummyApp.evaluate(SomeModule, :any_task) == 0.0
  end

  test "agents/0 and tasks/0 come from the EDN definition" do
    assert FunctionOptimizer.agents() == ["function_optimizer"]

    tasks = FunctionOptimizer.tasks()
    assert is_list(tasks) and length(tasks) == 4
    assert Enum.all?(tasks, &(is_map_key(&1, :input) and is_map_key(&1, :expect)))
  end

  test "evaluate/2 scores solve/1 output against the expected value" do
    {:ok, version} =
      Versions.load(
        @app,
        @agent,
        """
        defmodule FO.EvalCheck do
          def solve(x), do: 2 * x
        end
        """
      )

    assert FunctionOptimizer.evaluate(version, %{input: 3, expect: 6}) == 1.0
    assert FunctionOptimizer.evaluate(version, %{input: 3, expect: 7}) == 0.0
  end

  test "run/3 loads the initial version, self-improves it and logs evolution" do
    propose = fn _current ->
      {:ok,
       """
       defmodule FunctionOptimizer.V1 do
         def solve(x), do: 2 * x
       end
       """}
    end

    results = App.run(FunctionOptimizer, propose, rounds: 1)

    assert [%{agent: @agent, decision: :adopted, score: score}] = results
    assert score == 1.0

    current = Versions.current(@app, @agent)
    assert apply(current, :solve, [3]) == 6
    assert Versions.score(@app, @agent, current) == 1.0

    records = score_records()
    assert Enum.any?(records, &(&1["version"] == Atom.to_string(current)))

    adopted = Enum.find(records, &(&1["version"] == Atom.to_string(current)))
    assert adopted["score"] == 1.0
    assert adopted["parent"] != nil
    assert adopted["ts"] != nil
    assert adopted["app"] == "function_optimizer"
  end

  test "run/3 with rounds <= 0 runs setup but no improvement steps" do
    propose = fn _current -> flunk("propose must not be called") end

    assert App.run(FunctionOptimizer, propose, rounds: 0) == []
    assert Versions.current(@app, @agent) != nil
  end

  test "a worse proposal is rejected and the incumbent stays current" do
    propose = fn _current ->
      {:ok,
       """
       defmodule FunctionOptimizer.VBad do
         def solve(x), do: x - 100
       end
       """}
    end

    assert [%{decision: :rejected}] = App.run(FunctionOptimizer, propose, rounds: 1)

    current = Versions.current(@app, @agent)
    assert apply(current, :solve, [3]) == 4
    assert Versions.score(@app, @agent, current) == 0.25
  end

  defp score_records do
    path = Path.join("evolution", "function_optimizer.jsonl")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)
      |> Enum.filter(&(&1["type"] == "score"))
    else
      []
    end
  end
end
