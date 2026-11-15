defmodule Apps.FunctionOptimizer do
  @moduledoc """
  First sample app (FR-6/Phase 2): a single agent that rewrites its own
  `solve/1` function.

  The initial implementation and the evaluation tasks live in
  `agents/function_optimizer.edn`. Drive the self-improvement loop with
  `AgentLab.App.run/3`, passing a `propose` fun that returns candidate
  source (LLM-backed once the FR-2 loop lands, stubbed in tests):

      AgentLab.App.run(Apps.FunctionOptimizer, fn _current -> {:ok, source} end)
  """

  use AgentLab.App

  @agent "function_optimizer"

  def agents, do: [@agent]

  def tasks do
    case AgentLab.Definition.load(@agent) do
      {:ok, def} -> Enum.map(def.evaluation, &Map.take(&1, [:input, :expect]))
      _ -> []
    end
  end

  def evaluate(agent, %{input: input, expect: expect}) do
    try do
      if apply(agent, :solve, [input]) == expect, do: 1.0, else: 0.0
    catch
      _, _ -> 0.0
    end
  end

  def evaluate(_agent, _task), do: 0.0
end
