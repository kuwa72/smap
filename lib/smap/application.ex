defmodule Smap.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AgentLab.Versions,
      AgentLab.Blackboard,
      {Registry, keys: :unique, name: AgentLab.Registry},
      {DynamicSupervisor, name: AgentLab.Agents, strategy: :one_for_one},
      {Task.Supervisor, name: AgentLab.TaskSupervisor},
      AgentLab.Transport,
      Smap.Orchestrator,
      Smap.Chat.Session,
      Smap.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Smap.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
