defmodule TravelPlanner do
  @moduledoc """
  Phase 3 sample app (FR-4/FR-6): three role agents — budget, schedule and
  experience — negotiate over `AgentLab.Transport` envelopes and the app
  outputs the one itinerary the roles agree on.

  Flow: `plan/1` broadcasts a `:propose_itinerary` envelope on a per-call
  topic, each role agent scores every candidate from its own perspective and
  replies with a vote envelope, then `evaluate/2` applies the consensus rule
  (unanimous vote wins; otherwise the highest total score must clear the
  threshold).

  The "cognition" is a deterministic stub — real LLM calls are out of scope.
  """

  use AgentLab.App

  alias AgentLab.{Envelope, Transport}

  @roles [:budget, :schedule, :experience]
  @score_threshold 0.6
  @collect_timeout 1_000

  @impl true
  def agents, do: @roles

  @doc """
  Negotiate one itinerary for `brief`.

  `brief` must contain `:itineraries` — a non-empty list of candidate maps
  with `:id`, `:cost`, `:days` (list) and `:activities` (count) — plus the
  criteria the roles score against (`:budget`, `:days`). Returns the winning
  itinerary map, or `nil` when the roles cannot reach consensus.
  """
  @spec plan(map()) :: map() | nil
  def plan(%{itineraries: [_ | _] = candidates} = brief) do
    topic = {:travel_plan, System.unique_integer([:positive])}
    parent = self()

    for role <- @roles do
      spawn(fn -> agent(role, topic, parent) end)
    end

    for _ <- @roles do
      receive do
        {:ready, ^topic} -> :ok
      after
        @collect_timeout -> exit(:agent_timeout)
      end
    end

    proposal =
      Envelope.new(self(), :propose_itinerary, %{brief: brief, candidates: candidates},
        topic: topic
      )

    {:ok, _} = Transport.broadcast(proposal)

    votes =
      proposal.id
      |> Transport.collect(@collect_timeout)
      |> Enum.map(& &1.payload)

    case evaluate(votes) do
      {:ok, id} -> Enum.find(candidates, &(&1.id == id))
      :no_consensus -> nil
    end
  end

  @doc """
  Consensus judgement over vote payloads `%{role:, choice:, score:}`.

  A choice voted by every role wins outright. Otherwise the choice with the
  highest total score wins when its average score reaches `:threshold`
  (default #{@score_threshold}); anything weaker is `:no_consensus`.
  """
  @spec evaluate([map()], keyword()) :: {:ok, term()} | :no_consensus
  def evaluate(votes), do: evaluate(votes, [])

  @impl true
  def evaluate(votes, opts) do
    threshold = Keyword.get(opts, :threshold, @score_threshold)

    decisions =
      votes
      |> Enum.group_by(& &1.choice)
      |> Enum.map(fn {id, vs} ->
        %{id: id, count: length(vs), score: Enum.sum(Enum.map(vs, & &1.score))}
      end)

    unanimous = Enum.find(decisions, &(&1.count == length(@roles)))

    case unanimous do
      %{id: id} ->
        {:ok, id}

      nil ->
        with false <- decisions == [],
             %{score: total, count: count} = best when total > 0 <-
               Enum.max_by(decisions, &{&1.score, &1.count}),
             true <- total / count >= threshold do
          {:ok, best.id}
        else
          _ -> :no_consensus
        end
    end
  end

  # --- role agents ---------------------------------------------------------

  # Each agent claims its role seat (Contract Net), subscribes to the
  # negotiation topic, scores every candidate from its role's perspective and
  # replies with a vote envelope. One-shot: exits after replying.
  defp agent(role, topic, parent) do
    case Transport.claim({:seat, topic, role}) do
      {:ok, _} ->
        Transport.subscribe({:topic, topic})
        send(parent, {:ready, topic})

        receive do
          %Envelope{type: :propose_itinerary, payload: payload, from: from, id: id} ->
            %{brief: brief, candidates: candidates} = payload
            {choice, score} = best_for(role, candidates, brief)

            vote =
              Envelope.new(role, :itinerary_vote, %{role: role, choice: choice, score: score},
                to: from,
                in_reply_to: id
              )

            Transport.deliver(vote)
        after
          @collect_timeout -> :ok
        end

      {:error, :already_claimed} ->
        :ok
    end
  end

  defp best_for(role, candidates, brief) do
    candidates
    |> Enum.map(fn candidate -> {candidate.id, score(role, candidate, brief)} end)
    |> Enum.max_by(fn {_id, score} -> score end)
  end

  # Deterministic per-role scoring stub (replaces the LLM cognition step).
  defp score(:budget, %{cost: cost}, %{budget: budget}) do
    1.0 - min(cost / budget, 1.0)
  end

  defp score(:schedule, %{days: days}, %{days: wanted}) do
    1.0 - min(abs(length(days) - wanted) / wanted, 1.0)
  end

  defp score(:experience, %{activities: activities}, _brief) do
    min(activities / 8, 1.0)
  end
end
