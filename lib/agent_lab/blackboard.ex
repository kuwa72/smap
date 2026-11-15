defmodule AgentLab.Blackboard do
  @moduledoc """
  Optional ETS-backed shared blackboard (FR-4). Any process can
  `put/2`, `get/1` and `delete/1` key/value pairs.
  """

  use GenServer

  @table :agentlab_blackboard

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(term(), term()) :: :ok
  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end

  @spec get(term()) :: {:ok, term()} | :error
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
