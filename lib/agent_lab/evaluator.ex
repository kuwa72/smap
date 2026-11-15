defmodule AgentLab.Evaluator do
  @moduledoc """
  Scores agent versions (FR-3).

  `run/3` scores a version module over an app's task set: each task is
  evaluated by `app.evaluate(agent, task)` inside a separate process. A
  timeout or crash scores that task 0.0 without affecting the rest; the
  aggregate is the mean of per-task scores clamped to 0.0..1.0.

  `eval_version/4` scores a single candidate version through a
  context-provided evaluator — a 1-arity `(version -> score)` or 2-arity
  `(agent, version -> score)` function from `context[:evaluate]`, or
  `app.evaluate(agent, version)` as fallback — returning `{:ok, score}` or
  `{:error, reason}`. Used by the LLM improvement loop (`Evolution.step/3`).
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

  @doc "Score a single `version` via the context evaluator; `{:ok, score}` or `{:error, reason}`."
  @spec eval_version(atom(), atom(), module(), keyword()) :: {:ok, float()} | {:error, term()}
  def eval_version(app, agent, version, context \\ []) do
    case evaluator(app, context) do
      nil ->
        {:error, :no_evaluator}

      fun ->
        timeout = Keyword.get(context, :eval_timeout, 30_000)

        task =
          Task.Supervisor.async_nolink(AgentLab.TaskSupervisor, fn -> fun.(agent, version) end)

        case Task.yield(task, timeout) do
          {:ok, result} ->
            normalize(result)

          {:exit, reason} ->
            {:error, {:eval_crash, reason}}

          nil ->
            case Task.shutdown(task) do
              {:ok, result} -> normalize(result)
              _ -> {:error, :timeout}
            end
        end
    end
  end

  defp evaluator(app, context) do
    case Keyword.get(context, :evaluate) do
      fun when is_function(fun, 2) ->
        fun

      fun when is_function(fun, 1) ->
        fn _agent, version -> fun.(version) end

      _ ->
        if function_exported?(app, :evaluate, 2) do
          fn agent, version -> apply(app, :evaluate, [agent, version]) end
        end
    end
  end

  defp normalize(score) when is_number(score), do: {:ok, score * 1.0}
  defp normalize({:ok, score}) when is_number(score), do: {:ok, score * 1.0}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, {:bad_score, other}}

  defp task_score(app, agent, task, timeout) do
    pid =
      Task.Supervisor.async_nolink(AgentLab.TaskSupervisor, fn ->
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
