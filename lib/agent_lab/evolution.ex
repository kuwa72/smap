defmodule AgentLab.Evolution do
  @moduledoc """
  One LLM-driven self-improvement step (FR-2/FR-5):

      LLM proposal -> Versions.load -> Evaluator.run -> adopt / discard

  `context` is a keyword list:

    * `:prompt` (string) or `:messages` (list) — LLM input
    * `:chat` — optional `messages -> {:ok, text}` fun, defaults to `AgentLab.LLM.chat/1`
    * `:evaluate` — passed through to `AgentLab.Evaluator.run/4`
    * `:eval_timeout` — evaluation timeout in ms (default 30_000)

  Returns `{:ok, result}` where `result` has `:decision` (`:adopted` or
  `:discarded`), `:version`, `:score`, `:previous_version`, and `:previous_score`.
  """

  alias AgentLab.{Evaluator, LLM, Versions}

  @spec step(atom(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def step(app, agent, context) do
    previous = Versions.current(app, agent)

    with {:ok, source} <- propose(context),
         {:ok, version} <- Versions.load(app, agent, source) do
      case Evaluator.run(app, agent, version, context) do
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

  defp propose(context) do
    with {:ok, messages} <- llm_input(context) do
      chat = Keyword.get(context, :chat, &LLM.chat/1)

      case chat.(messages) do
        {:ok, text} when is_binary(text) -> {:ok, extract_source(text)}
        text when is_binary(text) -> {:ok, extract_source(text)}
        {:error, reason} -> {:error, reason}
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

    adopted? = is_nil(previous) or is_nil(previous_score) or score > previous_score

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
    case Evaluator.run(app, agent, previous, context) do
      {:ok, score} -> score
      {:error, _} -> nil
    end
  end
end
