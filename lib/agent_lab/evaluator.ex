defmodule AgentLab.Evaluator do
  @moduledoc """
  Scores a loaded agent version (FR-3 hook).

  The evaluator comes from `context[:evaluate]` — a 1-arity `(version -> score)`
  or 2-arity `(agent, version -> score)` function — or falls back to
  `app.evaluate(agent, version)` when the app module exports it. Scores may be
  returned bare or as `{:ok, score}`. Evaluation runs in a separate process
  with a timeout so a misbehaving version cannot hang the caller.
  """

  @default_timeout 30_000

  @spec run(atom(), atom(), module(), keyword()) :: {:ok, float()} | {:error, term()}
  def run(app, agent, version, context \\ []) do
    case evaluator(app, context) do
      nil ->
        {:error, :no_evaluator}

      fun ->
        timeout = Keyword.get(context, :eval_timeout, @default_timeout)
        task = Task.async(fn -> fun.(agent, version) end)

        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, result} -> normalize(result)
          nil -> {:error, :timeout}
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
end
