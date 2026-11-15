defmodule AgentLab.Agent do
  @moduledoc """
  Long-lived spawned agent (FR-7).

  Started under `AgentLab.Agents` (DynamicSupervisor) and registered in
  `AgentLab.Registry` under `{app, agent}`. The `{app, agent}` pair ties the
  process to `AgentLab.Versions`, so it inherits the version mechanism and the
  code it runs can recursively call `AgentLab.Tools`.
  """

  use GenServer

  @registry AgentLab.Registry

  def child_spec(opts) do
    %{id: {__MODULE__, key(opts)}, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Current version module for this agent's `{app, agent}`, or nil."
  @spec version(pid()) :: module() | nil
  def version(pid), do: GenServer.call(pid, :version)

  @impl true
  def init(opts) do
    app = Keyword.fetch!(opts, :app)
    agent = Keyword.fetch!(opts, :agent)
    {:ok, _} = Registry.register(@registry, {app, agent}, self())
    {:ok, %{app: app, agent: agent}}
  end

  @impl true
  def handle_call(:version, _from, state) do
    {:reply, AgentLab.Versions.current(state.app, state.agent), state}
  end

  def handle_call({:run, {fun, timeout}}, _from, state) do
    {:reply, AgentLab.Tools.run_isolated(fun, timeout), state}
  end

  defp key(opts), do: {Keyword.fetch!(opts, :app), Keyword.fetch!(opts, :agent)}
end
