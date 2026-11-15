defmodule Smap.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AgentLab.Versions,
      {Registry, keys: :unique, name: AgentLab.Registry},
      {DynamicSupervisor, name: AgentLab.Agents, strategy: :one_for_one},
      {Task.Supervisor, name: AgentLab.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Smap.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
