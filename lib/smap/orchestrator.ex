defmodule Smap.Orchestrator do
  @moduledoc """
  Resident orchestrator: turns a natural-language goal into a working
  `AgentLab.App`.

  Pipeline: LLM designs the app (JSON spec) -> `agents/*.edn` and
  `lib/apps/<app>.ex` are written -> the app module is compiled and
  hot-loaded -> `AgentLab.App.setup` + one LLM-proposed improvement round
  per agent. `AgentLab.LLM.chat/1` is used unless
  `Application.get_env(:smap, :orchestrator_chat)` provides a fun.
  """

  use GenServer

  alias AgentLab.{App, EDN, LLM, Versions}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Submit a goal; returns :ok or {:error, :busy} while a goal runs."
  @spec submit_goal(String.t()) :: :ok | {:error, :busy}
  def submit_goal(goal) when is_binary(goal) do
    GenServer.call(__MODULE__, {:submit, goal})
  end

  @doc "Orchestrator state: %{status, goal, result}."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    {:ok, %{status: :idle, goal: nil, result: nil}}
  end

  @impl true
  def handle_call({:submit, _goal}, _from, %{status: :running} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:submit, goal}, _from, state) do
    me = self()

    Task.Supervisor.start_child(AgentLab.TaskSupervisor, fn ->
      result =
        try do
          run_goal(goal)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      GenServer.cast(me, {:finished, result})
    end)

    {:reply, :ok, %{state | status: :running, goal: goal, result: nil}}
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:finished, {:ok, result}}, state) do
    {:noreply, %{state | status: :done, result: result}}
  end

  def handle_cast({:finished, {:error, reason}}, state) do
    {:noreply, %{state | status: {:error, reason}, result: nil}}
  end

  # --- pipeline ---

  defp run_goal(goal) do
    with {:ok, spec} <- design(goal),
         :ok <- persist(spec),
         {:ok, app_mod} <- load_app(spec),
         {:ok, results} <- improve_all(app_mod, spec) do
      {:ok,
       %{app: spec["app"], module: app_mod, agents: length(spec["agents"]), results: results}}
    end
  end

  defp design(goal) do
    prompt = """
    You are designing a self-improving agent application for the smap AgentLab framework (Elixir/OTP on BEAM).

    Goal: #{goal}

    Contract:
    - "module": a full Elixir module source. It MUST start with `defmodule Apps.<Name> do`, contain `use AgentLab.App`, and implement agents/0, tasks/0, evaluate/2.
    - agents/0 returns the agent name strings; tasks/0 returns the task list; evaluate(agent_version_module, task) scores one task (convention: apply(version, :solve, [task.input]) compared to task.expect, returning 1.0 or 0.0).
    - "agents": list of agent definitions. Each has "name" (snake_case string matching an agents/0 entry), "role", "prompt" (what the agent should optimize), "code_template" (Elixir source whose FIRST defmodule defines the agent code and exposes solve/1), "tools" ([]), "evaluation" (list of {"input": ..., "expect": ...}).

    Return ONLY a JSON object, no markdown fences:
    {"app": "...", "module": "...", "agents": [...]}
    """

    do_design(prompt, 2)
  end

  defp do_design(_prompt, 0), do: {:error, :invalid_spec}

  defp do_design(prompt, attempts) do
    case chat([%{role: "user", content: prompt}]) do
      {:ok, text} ->
        case parse_spec(text) do
          {:ok, _spec} = ok -> ok
          {:error, _} -> do_design(prompt, attempts - 1)
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_spec(text) do
    with {:ok, json} <- extract_json(text),
         {:ok, spec} <- json |> :json.decode() |> normalize_spec() do
      {:ok, spec}
    else
      _ -> {:error, :invalid_spec}
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/```(?:json)?\s*\n(.*?)```/s, text) do
      [_, json] ->
        {:ok, json}

      _ ->
        case Regex.run(~r/\{.*\}/s, text) do
          [json] -> {:ok, json}
          _ -> {:error, :no_json}
        end
    end
  end

  @name_pattern ~r/^[a-z0-9_]+$/

  defp normalize_spec(%{"app" => app, "module" => module, "agents" => agents})
       when is_binary(app) and is_binary(module) and is_list(agents) and agents != [] do
    with true <- Regex.match?(@name_pattern, app),
         {:ok, agents} <- normalize_agents(agents) do
      {:ok, %{"app" => app, "module" => module, "agents" => agents}}
    else
      _ -> {:error, :invalid_spec}
    end
  end

  defp normalize_spec(_), do: {:error, :invalid_spec}

  defp normalize_agents(agents) do
    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, acc} ->
      name = is_map(agent) && agent["name"]
      code_template = is_map(agent) && agent["code_template"]

      cond do
        not is_binary(name) or not is_binary(code_template) ->
          {:halt, {:error, :invalid_agent}}

        not Regex.match?(@name_pattern, name) ->
          {:halt, {:error, :invalid_agent_name}}

        true ->
          {:cont,
           {:ok,
            [
              %{
                "name" => name,
                "role" => agent["role"] || name,
                "prompt" => agent["prompt"] || "",
                "code_template" => code_template,
                "tools" => list_or_empty(agent["tools"]),
                "evaluation" => list_or_empty(agent["evaluation"])
              }
              | acc
            ]}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp persist(spec) do
    File.mkdir_p!("agents")
    File.mkdir_p!("lib/apps")

    Enum.each(spec["agents"], fn agent ->
      definition = %{
        name: agent["name"],
        role: agent["role"],
        prompt: agent["prompt"],
        code_template: agent["code_template"],
        tools: agent["tools"],
        evaluation: normalize_evaluation(agent["evaluation"])
      }

      File.write!(Path.join("agents", "#{agent["name"]}.edn"), EDN.encode(definition))
    end)

    File.write!(Path.join("lib/apps", "#{spec["app"]}.ex"), spec["module"])
    :ok
  end

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_), do: []

  defp normalize_evaluation(evaluation) when is_list(evaluation) do
    Enum.flat_map(evaluation, fn
      %{"input" => input, "expect" => expect} -> [%{input: input, expect: expect}]
      _ -> []
    end)
  end

  defp normalize_evaluation(_), do: []

  defp load_app(spec) do
    try do
      case Code.compile_string(spec["module"]) do
        [] ->
          {:error, :no_module_compiled}

        compiled ->
          Enum.each(compiled, fn {mod, bin} -> :code.load_binary(mod, ~c"orchestrator", bin) end)

          case Enum.find(compiled, fn {mod, _} -> app_module?(mod) end) do
            {mod, _} -> {:ok, mod}
            nil -> {:error, :no_app_module}
          end
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp app_module?(mod) do
    case Module.split(mod) do
      ["Apps" | _] -> true
      _ -> false
    end
  end

  defp improve_all(app_mod, spec) do
    app = App.app_key(app_mod)
    setup = App.setup(app_mod)

    results =
      for name <- app_mod.agents() do
        propose = fn _current -> propose_source(app, name, spec) end
        Map.put(App.improve(app_mod, name, propose), :setup, setup_result(setup, name))
      end

    {:ok, results}
  end

  defp setup_result(setup, name) do
    case List.keyfind(setup, name, 0) do
      {^name, {:ok, _version, score}} -> {:ok, score}
      {^name, {:error, reason}} -> {:error, reason}
      nil -> :skipped
    end
  end

  defp propose_source(app, name, spec) do
    agent = Enum.find(spec["agents"], &(&1["name"] == name))
    current = Versions.source(app, name) || (agent && agent["code_template"]) || ""

    prompt = """
    Improve this Elixir agent module.

    Agent: #{name}
    Role: #{agent && agent["role"]}
    Goal prompt: #{agent && agent["prompt"]}

    Current code:
    ```elixir
    #{current}
    ```

    Evaluation tasks: #{inspect(agent && agent["evaluation"])}

    Return ONLY the full improved module source in a ```elixir fenced block.
    The FIRST defmodule in your answer is the agent code and must expose solve/1.
    """

    case chat([%{role: "user", content: prompt}]) do
      {:ok, text} -> {:ok, extract_source(text)}
      {:error, _} = error -> error
    end
  end

  defp extract_source(text) do
    case Regex.run(~r/```(?:\w+)?\s*\n(.*?)```/s, text) do
      [_, code] -> String.trim(code)
      _ -> String.trim(text)
    end
  end

  defp chat(messages) do
    fun = Application.get_env(:smap, :orchestrator_chat, &LLM.chat/1)
    fun.(messages)
  end
end
