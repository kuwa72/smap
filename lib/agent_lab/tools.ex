defmodule AgentLab.Tools do
  @moduledoc """
  Dynamic process tools (FR-7).

  `spawn_agent/1` starts a long-lived `AgentLab.Agent` under
  `AgentLab.Agents` (DynamicSupervisor), registered in `AgentLab.Registry`
  under `{app, agent}`. `delegate/2,3` runs a function in an isolated
  process under `AgentLab.TaskSupervisor` with a timeout, so generated code
  can never take the caller down. `list_processes/0` enumerates agents.
  """

  @agents AgentLab.Agents
  @registry AgentLab.Registry
  @tasks AgentLab.TaskSupervisor

  @doc "Start a long-lived agent process registered under `{app, agent}`."
  @spec spawn_agent(keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent(opts) do
    DynamicSupervisor.start_child(@agents, AgentLab.Agent.child_spec(opts))
  end

  @doc """
  Run `fun` in an isolated task process.

  Without a target the task runs directly under the task supervisor. With a
  target (pid or `{app, agent}` registry key) the agent executes `fun` in its
  own isolated task and replies with the result.
  """
  @spec delegate(function() | pid() | {atom(), atom()}, function() | keyword(), keyword()) ::
          term()
  def delegate(fun) when is_function(fun, 0), do: delegate(fun, [])

  def delegate(fun, opts) when is_function(fun, 0) do
    run_isolated(fun, Keyword.get(opts, :timeout, 5_000))
  end

  def delegate(target, fun) when is_function(fun, 0), do: delegate(target, fun, [])

  def delegate(target, fun, opts) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, pid} <- resolve(target) do
      GenServer.call(pid, {:run, {fun, timeout}}, timeout + 5_000)
    end
  end

  @doc "List spawned agent processes as `%{pid, key}` maps."
  @spec list_processes() :: [%{pid: pid(), key: {atom(), atom()}}]
  def list_processes do
    pids =
      for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(@agents),
          is_pid(pid),
          do: pid

    for {key, pid} <- Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]),
        pid in pids do
      %{pid: pid, key: key}
    end
  end

  @doc false
  @spec run_isolated(function(), timeout()) :: {:ok, term()} | {:error, term()}
  def run_isolated(fun, timeout) do
    task = Task.Supervisor.async_nolink(@tasks, fun)

    case Task.yield(task, timeout) do
      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}

      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:error, reason}
    end
  end

  defp resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve({app, agent}) do
    case Registry.lookup(@registry, {app, agent}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :unknown_agent}
    end
  end
end
