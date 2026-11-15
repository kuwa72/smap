defmodule AgentLab.Transport do
  @moduledoc """
  Envelope transport and coordination primitives (FR-4).

  `deliver/1` routes an `%AgentLab.Envelope{}` by destination:

    * `to` is a pid — sent directly
    * `to` is a role name — sent to every process `subscribe({:role, name})`d
    * `to` is nil and `topic` is set — sent to every `{:topic, topic}` subscriber

  `broadcast/1` sends a proposal to all subscribers (or only one topic when the
  envelope carries `topic`). `collect/2` is the fan-in half: it gathers reply
  envelopes whose `in_reply_to` matches `proposal_id` until `timeout` ms elapse.
  `claim/1` is the Contract Net primitive: the first claimant of a task id wins,
  everyone else gets `{:error, :already_claimed}`.
  """

  use GenServer

  alias AgentLab.Envelope

  @subs :agentlab_subscriptions
  @claims :agentlab_claims

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe the caller. `key` is `{:role, name}` or `{:topic, topic}`."
  @spec subscribe({atom(), term()}) :: :ok
  def subscribe({kind, _name} = key) when kind in [:role, :topic] do
    :ets.insert(@subs, {key, self()})
    GenServer.cast(__MODULE__, {:watch, self()})
    :ok
  end

  @doc "Route an envelope to its destination. Returns `:ok`."
  @spec deliver(Envelope.t()) :: :ok
  def deliver(%Envelope{to: to, topic: topic} = env) do
    case to do
      nil -> fanout(topic_key(topic), env)
      pid when is_pid(pid) -> send(pid, env)
      role -> fanout({:role, role}, env)
    end

    :ok
  end

  @doc "Send `proposal` to all subscribers; with `topic` set, only that topic."
  @spec broadcast(Envelope.t()) :: {:ok, non_neg_integer()}
  def broadcast(%Envelope{topic: nil} = env) do
    pids = @subs |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    Enum.each(pids, &send(&1, env))
    {:ok, length(pids)}
  end

  def broadcast(%Envelope{} = env) do
    deliver(env)
    {:ok, count_for({:topic, env.topic})}
  end

  @doc """
  Collect reply envelopes with `in_reply_to == proposal_id` until `timeout`
  milliseconds elapse. Returns the replies found (possibly empty).
  """
  @spec collect(term(), non_neg_integer()) :: [Envelope.t()]
  def collect(proposal_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(proposal_id, deadline, [])
  end

  @doc """
  Claim `task` (a map with `:id`, or any term used as the key). Only the first
  claimant wins; later claimants get `{:error, :already_claimed}`.
  """
  @spec claim(term()) :: {:ok, term()} | {:error, :already_claimed}
  def claim(task) do
    key = if is_map(task), do: Map.get(task, :id, task), else: task

    if :ets.insert_new(@claims, {key, self()}) do
      {:ok, task}
    else
      {:error, :already_claimed}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@subs, [:named_table, :public, :bag])
    :ets.new(@claims, [:named_table, :public, :set])
    {:ok, %{watched: MapSet.new()}}
  end

  @impl true
  def handle_cast({:watch, pid}, state) do
    if MapSet.member?(state.watched, pid) do
      {:noreply, state}
    else
      Process.monitor(pid)
      {:noreply, %{state | watched: MapSet.put(state.watched, pid)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.match_delete(@subs, {{:_, :_}, pid})
    {:noreply, %{state | watched: MapSet.delete(state.watched, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp topic_key(nil), do: nil
  defp topic_key(topic), do: {:topic, topic}

  defp fanout(nil, _env), do: :ok

  defp fanout(key, env) do
    key
    |> subscribers()
    |> Enum.each(&send(&1, env))

    :ok
  end

  defp subscribers(key) do
    :ets.lookup(@subs, key) |> Enum.map(fn {_key, pid} -> pid end)
  end

  defp count_for(key), do: length(subscribers(key))

  defp do_collect(proposal_id, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        %Envelope{in_reply_to: ^proposal_id} = env ->
          do_collect(proposal_id, deadline, [env | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end
end
