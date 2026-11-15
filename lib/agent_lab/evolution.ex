defmodule AgentLab.Evolution do
  @moduledoc """
  Adoption gate for self-modification (FR-3).

  A candidate version is adopted only when its score strictly beats the
  incumbent's score; otherwise it is discarded. `:rejected` never moves the
  pointer by itself — a freshly loaded candidate that is still current is
  restored to the version that was current before it was loaded.
  """

  alias AgentLab.Versions

  @doc "true when `new_score` is strictly greater than `current_score`."
  @spec adopt?(number(), number()) :: boolean()
  def adopt?(new_score, current_score), do: new_score > current_score

  @doc """
  Adopt `version` for `{app, agent}` when `new_score` beats the incumbent
  score: activates it and appends a score record. Returns `:adopted` or
  `:rejected`.

  `version` is expected to have been loaded already, which makes it current.
  The incumbent is the version that was current before `version` was loaded
  (or `version` itself when it is being re-scored). On rejection the pointer
  is restored to the incumbent only when `version` is an unscored candidate
  still sitting on the pointer.
  """
  @spec maybe_adopt(atom(), atom(), module(), number()) :: :adopted | :rejected | {:error, term()}
  def maybe_adopt(app, agent, version, new_score) do
    current = Versions.current(app, agent)

    {incumbent, fresh_candidate?} =
      cond do
        current == version and is_nil(Versions.score(app, agent, version)) ->
          {Versions.previous(app, agent), true}

        current == version ->
          {version, false}

        true ->
          {current, false}
      end

    baseline = (incumbent && Versions.score(app, agent, incumbent)) || -1.0

    if adopt?(new_score, baseline) do
      parent = if incumbent == version, do: Versions.previous(app, agent), else: incumbent

      with :ok <- activate_unless_current(app, agent, version, current),
           :ok <- Versions.record_score(app, agent, version, new_score, parent) do
        :adopted
      else
        {:error, reason} -> {:error, reason}
      end
    else
      if fresh_candidate? and incumbent, do: Versions.activate(app, agent, incumbent)
      :rejected
    end
  end

  defp activate_unless_current(_app, _agent, version, version), do: :ok

  defp activate_unless_current(app, agent, version, _current),
    do: Versions.activate(app, agent, version)
end
