defmodule AgentLab.Evolution do
  @moduledoc """
  Self-improvement loop and adoption gate (FR-2/FR-3/FR-5).

  `step/3` runs one LLM-driven step:

      LLM proposal -> Versions.load -> Evaluator.eval_version -> adopt / discard

  `context` is a keyword list:

    * `:prompt` (string) or `:messages` (list) — LLM input
    * `:chat` — optional `messages -> {:ok, text}` fun, defaults to `AgentLab.LLM.chat/1`
    * `:evaluate` — passed through to `AgentLab.Evaluator.eval_version/4`
    * `:eval_timeout` — evaluation timeout in ms (default 30_000)

  `adopt?/2` and `maybe_adopt/4` are the score-based adoption gate used by
  `AgentLab.App.improve/3`: a candidate is adopted only when its score
  strictly beats the incumbent's.
  """

  alias AgentLab.{Evaluator, LLM, Versions}

  @spec step(atom(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def step(app, agent, context) do
    previous = Versions.current(app, agent)

    with {:ok, source} <- propose(context),
         {:ok, version} <- Versions.load(app, agent, source) do
      case Evaluator.eval_version(app, agent, version, context) do
        {:ok, score} ->
          decide(app, agent, version, score, previous, context)

        {:error, reason} ->
          Versions.discard(app, agent)

          {:ok,
           %{
             decision: :discarded,
             version: version,
             score: nil,
             error: reason,
             previous_version: previous,
             previous_score: nil
           }}
      end
    end
  end

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

  defp propose(context) do
    with {:ok, messages} <- llm_input(context) do
      chat = Keyword.get(context, :chat, &LLM.chat/1)

      case chat.(messages) do
        {:ok, text} when is_binary(text) -> {:ok, extract_source(text)}
        text when is_binary(text) -> {:ok, extract_source(text)}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:bad_chat_response, other}}
      end
    end
  end

  defp llm_input(context) do
    cond do
      messages = context[:messages] -> {:ok, messages}
      prompt = context[:prompt] -> {:ok, [%{role: "user", content: prompt}]}
      true -> {:error, :missing_prompt}
    end
  end

  defp extract_source(text) do
    case Regex.run(~r/```(?:\w+)?\s*\n(.*?)```/s, text) do
      [_, code] -> String.trim(code)
      _ -> String.trim(text)
    end
  end

  defp decide(app, agent, version, score, previous, context) do
    previous_score = previous_score(app, agent, previous, context)

    adopted? =
      is_nil(previous) or
        (is_nil(previous_score) and score > 0) or
        (not is_nil(previous_score) and score > previous_score)

    if adopted? do
      Versions.record_score(app, agent, version, score, previous)

      {:ok,
       %{
         decision: :adopted,
         version: version,
         score: score,
         previous_version: previous,
         previous_score: previous_score
       }}
    else
      Versions.discard(app, agent)
      Versions.record_score(app, agent, version, score, previous)

      {:ok,
       %{
         decision: :discarded,
         version: version,
         score: score,
         previous_version: previous,
         previous_score: previous_score
       }}
    end
  end

  defp previous_score(_app, _agent, nil, _context), do: nil

  defp previous_score(app, agent, previous, context) do
    case Evaluator.eval_version(app, agent, previous, context) do
      {:ok, score} -> score
      {:error, _} -> nil
    end
  end
end
