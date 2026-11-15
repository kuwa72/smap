defmodule AgentLab.TransportTest do
  use ExUnit.Case

  alias AgentLab.{Envelope, Transport}

  defp subscribe_and_reply(parent, topic) do
    spawn(fn ->
      Transport.subscribe({:topic, topic})
      send(parent, {:ready, self()})

      receive do
        %Envelope{} = env ->
          reply =
            Envelope.new(self(), :reply, {:answered, env.payload},
              to: env.from,
              in_reply_to: env.id
            )

          Transport.deliver(reply)
      end
    end)
  end

  test "deliver/1 sends an envelope to a pid" do
    env = Envelope.new(self(), :ping, :hello, to: self())
    assert :ok = Transport.deliver(env)
    assert_receive %Envelope{payload: :hello, to: pid} when pid == self()
  end

  test "deliver/1 sends an envelope to a role name" do
    Transport.subscribe({:role, :worker})
    env = Envelope.new(self(), :ping, :role_msg, to: :worker)
    assert :ok = Transport.deliver(env)
    assert_receive %Envelope{payload: :role_msg}
  end

  test "deliver/1 fans out to all topic subscribers" do
    test_pid = self()

    spawn(fn ->
      Transport.subscribe({:topic, :alerts})
      send(test_pid, :ready)

      receive do
        %Envelope{} = env -> send(test_pid, {:got, env.payload})
      end
    end)

    Transport.subscribe({:topic, :alerts})
    assert_receive :ready

    env = Envelope.new(self(), :alert, :fire, topic: :alerts)
    assert :ok = Transport.deliver(env)

    assert_receive {:got, :fire}
    assert_receive %Envelope{payload: :fire}
  end

  test "broadcast/1 reaches every subscriber once per pid" do
    Transport.subscribe({:role, :bcast_a})
    Transport.subscribe({:topic, :bcast_t})

    env = Envelope.new(self(), :proposal, :broadcast_payload)
    assert {:ok, count} = Transport.broadcast(env)
    assert count >= 1
    assert_receive %Envelope{payload: :broadcast_payload}
    refute_receive %Envelope{payload: :broadcast_payload}
  end

  test "broadcast/1 with a topic only reaches that topic" do
    Transport.subscribe({:topic, :only_topic})

    test_pid = self()

    spawn(fn ->
      Transport.subscribe({:topic, :other_topic})
      send(test_pid, :ready)

      receive do
        %Envelope{} -> send(test_pid, :unexpected)
      end
    end)

    assert_receive :ready

    env = Envelope.new(self(), :proposal, :scoped, topic: :only_topic)
    assert {:ok, _} = Transport.broadcast(env)
    assert_receive %Envelope{payload: :scoped}
    refute_received :unexpected
  end

  test "collect/2 gathers replies until timeout" do
    subscribe_and_reply(self(), :collect_topic)
    subscribe_and_reply(self(), :collect_topic)
    assert_receive {:ready, _}
    assert_receive {:ready, _}

    env = Envelope.new(self(), :proposal, :task, topic: :collect_topic)
    assert {:ok, _} = Transport.broadcast(env)

    replies = Transport.collect(env.id, 500)
    assert length(replies) == 2
    assert Enum.all?(replies, &(&1.payload == {:answered, :task}))
    assert Enum.all?(replies, &(&1.in_reply_to == env.id))
  end

  test "collect/2 returns partial results and empty list on timeout" do
    subscribe_and_reply(self(), :collect_slow)
    assert_receive {:ready, _}

    env = Envelope.new(self(), :proposal, :slow_task, topic: :collect_slow)
    assert {:ok, _} = Transport.broadcast(env)

    assert [%Envelope{}] = Transport.collect(env.id, 200)
    assert [] = Transport.collect(:nonexistent_id, 50)
  end

  test "claim/1 lets exactly one claimant win a contested task" do
    task = %{id: :contested_task, spec: "do work"}
    parent = self()

    for _ <- 1..5 do
      spawn(fn ->
        result = Transport.claim(task)
        send(parent, {:claim, result})
      end)
    end

    received =
      for _ <- 1..5 do
        receive do
          {:claim, result} -> result
        after
          1000 -> flunk("claimant did not respond")
        end
      end

    assert Enum.count(received, &match?({:ok, _}, &1)) == 1
    assert Enum.count(received, &match?({:error, :already_claimed}, &1)) == 4

    # the winner keeps the claim; a late claimer still loses
    assert {:error, :already_claimed} = Transport.claim(task)
  end

  test "claim/1 succeeds for distinct tasks" do
    assert {:ok, %{id: :a}} = Transport.claim(%{id: :a})
    assert {:ok, %{id: :b}} = Transport.claim(%{id: :b})
  end

  test "blackboard put/get/delete" do
    assert :ok = AgentLab.Blackboard.put(:k, :v)
    assert {:ok, :v} = AgentLab.Blackboard.get(:k)
    assert :error = AgentLab.Blackboard.get(:missing)
    assert :ok = AgentLab.Blackboard.delete(:k)
    assert :error = AgentLab.Blackboard.get(:k)
  end
end
