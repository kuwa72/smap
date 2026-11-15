defmodule AgentLab.Evolution do
  @moduledoc """
  Adoption gate for self-modification (FR-3).

  A candidate version is adopted only when its score strictly beats the
  incumbent's last recorded score; otherwise it is discarded and the
  pointer is rolled back if the candidate had been made current.
  """

  @doc "true when `new_score` is strictly greater than `current_score`."
  @spec adopt?(number(), number()) :: boolean()
  def adopt?(new_score, current_score), do: new_score > current_score

  @doc """
  Adopt `version` for `{app, agent}` when `new_score` beats the incumbent
  score: activates it and appends a score record. Returns `:adopted` or
  `:rejected`.
  """
  @spec maybe_adopt(atom(), atom(), module(), number()) :: :adopted | :rejected | {:error, term()}
  def maybe_adopt(app, agent, version, new_score) do
    current_score = AgentLab.Versions.current_score(app, agent) || -1.0

    if adopt?(new_score, current_score) do
      history = AgentLab.Versions.history(app, agent)
      idx = Enum.find_index(history, &(&1 == version))
      parent = (idx != nil and idx > 0) && Enum.at(history, idx - 1)

      with :ok <- AgentLab.Versions.activate(app, agent, version),
           :ok <- AgentLab.Versions.record_score(app, agent, version, new_score, parent) do
        :adopted
      else
        {:error, reason} -> {:error, reason}
      end
    else
      if AgentLab.Versions.current(app, agent) == version do
        AgentLab.Versions.rollback(app, agent)
      end

      :rejected
    end
  end
end
