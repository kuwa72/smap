defmodule AgentLab.Evaluator do
  @moduledoc """
  Scores an agent over a task set with timeout isolation (FR-3).

  Each task is evaluated by `app.evaluate(agent, task)` inside a separate
  process. A timeout or crash scores that task 0.0 without affecting the
  rest; the aggregate is the mean of per-task scores clamped to 0.0..1.0.
  """

  @default_timeout 5_000

  @doc "Score `agent` over `tasks`; returns the mean score in 0.0..1.0."
  @spec run(module(), module(), [term()]) :: float()
  def run(app, agent, tasks), do: run(app, agent, tasks, [])

  @doc "Same as `run/3` with options: `:timeout` (ms) per task, default #{@default_timeout}."
  @spec run(module(), module(), [term()], keyword()) :: float()
  def run(app, agent, tasks, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    scores = Enum.map(tasks, &task_score(app, agent, &1, timeout))

    case scores do
      [] -> 0.0
      _ -> Enum.sum(scores) / length(scores)
    end
  end

  defp task_score(app, agent, task, timeout) do
    pid =
      Task.async(fn ->
        try do
          app.evaluate(agent, task)
        catch
          kind, reason -> {:__eval_error__, {kind, reason}}
        end
      end)

    case Task.yield(pid, timeout) do
      {:ok, score} when is_number(score) ->
        score |> max(0.0) |> min(1.0)

      {:ok, _} ->
        0.0

      {:exit, _} ->
        0.0

      nil ->
        Task.shutdown(pid, :brutal_kill)
        0.0
    end
  end
end
