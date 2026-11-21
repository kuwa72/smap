defmodule Smap.AppSpace.Manager do
  @moduledoc """
  Manages the dynamic application space (`Smap.AppSpace`).

  Compiles and hot-swaps user-generated `Smap.UserApp.*` modules without
  stopping the process, supervises their child processes under
  `Smap.AppSpace.Supervisor`, broadcasts SSE update events, and automatically
  rolls back to the previous stable version on compile, startup, or render
  failure.
  """

  use GenServer

  alias AgentLab.Tools
  alias Smap.AppSpace.Safety
  alias Smap.Chat.Session
  alias Smap.Web.AppSlot

  @supervisor Smap.AppSpace.Supervisor
  @compile_timeout 10_000
  @smoke_timeout 2_000
  @request_timeout 5_000

  @type version_entry :: %{
          version: pos_integer(),
          module: module(),
          modules: [module()],
          source: String.t(),
          meta: %{name: String.t(), description: String.t()},
          loaded_at: String.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Validate, compile, load, smoke-test, and activate a new app version."
  @spec deploy(String.t()) :: {:ok, version_entry()} | {:error, term()}
  def deploy(source) when is_binary(source) do
    GenServer.call(__MODULE__, {:deploy, source}, 20_000)
  end

  @doc "Roll back to the previous version in history."
  @spec rollback() :: {:ok, version_entry()} | {:error, :no_previous_version | term()}
  def rollback do
    GenServer.call(__MODULE__, :rollback, 15_000)
  end

  @doc "Return the currently active version entry, or nil."
  @spec current() :: version_entry() | nil
  def current do
    GenServer.call(__MODULE__, :current)
  end

  @doc "Return all successfully deployed versions, oldest first."
  @spec history() :: [version_entry()]
  def history do
    GenServer.call(__MODULE__, :history)
  end

  @doc "Return runtime status summary for inspection."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Render the currently active app, or the default placeholder."
  @spec render_current() :: String.t()
  def render_current do
    case current() do
      nil -> AppSlot.default_render()
      %{module: mod} -> mod.render(%{})
    end
  end

  @doc "Dispatch an HTTP request to the active app inside an isolated task."
  @spec handle_request(String.t(), [String.t()], map()) ::
          {:ok, pos_integer(), [{String.t(), String.t()}], iodata()}
          | {:file, Path.t(), String.t()}
          | {:error, term()}
  def handle_request(method, path_segments, params \\ %{}) do
    case current() do
      nil ->
        {:error, :no_app}

      %{module: mod} ->
        if function_exported?(mod, :handle_request, 3) do
          case Tools.run_isolated(
                 fn -> mod.handle_request(method, path_segments, params) end,
                 @request_timeout
               ) do
            {:ok, {:ok, status, headers, body}} -> {:ok, status, headers, body}
            {:ok, {:file, path, content_type}} -> {:file, path, content_type}
            {:ok, other} -> {:error, {:invalid_response, other}}
            {:error, reason} -> {:error, reason}
          end
        else
          {:ok, 404, [{"content-type", "application/json"}], ~s({"error":"not_found"})}
        end
    end
  end

  @doc "Stop all running app children and clear state."
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset, 10_000)
  end

  @impl true
  def init(_opts) do
    {:ok, %{history: [], current_index: nil, last_error: nil}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, current_entry(state), state}
  end

  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:status, _from, state) do
    cur = current_entry(state)

    running =
      for {_id, pid, _type, mods} <- DynamicSupervisor.which_children(@supervisor),
          is_pid(pid) do
        %{pid: inspect(pid), modules: Enum.map(mods, &inspect/1)}
      end

    {:reply,
     %{
       current: cur && %{version: cur.version, module: inspect(cur.module), meta: cur.meta},
       history_count: length(state.history),
       running_children: running,
       last_error: state.last_error
     }, state}
  end

  def handle_call(:reset, _from, _state) do
    stop_all_children()
    {:reply, :ok, %{history: [], current_index: nil, last_error: nil}}
  end

  def handle_call({:deploy, source}, _from, state) do
    prev = current_entry(state)

    with :ok <- Safety.validate(source),
         {:ok, compiled} <- compile_isolated(source),
         {:ok, main_mod, all_mods} <- load_compiled(compiled),
         :ok <- activate_version(main_mod, prev) do
      meta = safe_meta(main_mod)
      next_version = length(state.history) + 1

      entry = %{
        version: next_version,
        module: main_mod,
        modules: all_mods,
        source: source,
        meta: meta,
        loaded_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      new_history = state.history ++ [entry]

      new_state = %{
        state
        | history: new_history,
          current_index: next_version - 1,
          last_error: nil
      }

      broadcast_update(entry)
      {:reply, {:ok, entry}, new_state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: format_error(reason)}}
    end
  end

  def handle_call(:rollback, _from, %{current_index: idx} = state)
      when is_integer(idx) and idx > 0 do
    target_idx = idx - 1
    target = Enum.at(state.history, target_idx)
    prev = current_entry(state)

    case activate_version(target.module, prev) do
      :ok ->
        new_state = %{state | current_index: target_idx, last_error: nil}
        broadcast_update(target)
        {:reply, {:ok, target}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: format_error(reason)}}
    end
  end

  def handle_call(:rollback, _from, state) do
    {:reply, {:error, :no_previous_version}, state}
  end

  # --- internals ---

  defp current_entry(%{current_index: nil}), do: nil
  defp current_entry(%{history: history, current_index: idx}), do: Enum.at(history, idx)

  defp compile_isolated(source) do
    case Tools.run_isolated(fn -> Code.compile_string(source) end, @compile_timeout) do
      {:ok, [{_, _} | _] = compiled} -> {:ok, compiled}
      {:ok, []} -> {:error, :no_modules_compiled}
      {:error, reason} -> {:error, {:compile_error, format_error(reason)}}
    end
  end

  defp load_compiled(compiled) do
    Enum.each(compiled, fn {mod, bin} -> :code.load_binary(mod, ~c"app_space", bin) end)
    mods = Enum.map(compiled, &elem(&1, 0))
    main_mod = Enum.find(mods, &function_exported?(&1, :render, 1)) || hd(mods)
    {:ok, main_mod, mods}
  end

  defp activate_version(new_mod, prev_entry) do
    stop_all_children()

    with :ok <- start_children(new_mod),
         :ok <- smoke_test_render(new_mod) do
      :ok
    else
      {:error, reason} ->
        stop_all_children()
        if prev_entry, do: start_children(prev_entry.module)
        {:error, reason}
    end
  end

  defp start_children(mod) do
    specs =
      if function_exported?(mod, :child_specs, 0) do
        case Tools.run_isolated(fn -> mod.child_specs() end, @smoke_timeout) do
          {:ok, list} when is_list(list) -> {:ok, list}
          {:ok, other} -> {:error, {:invalid_child_specs, other}}
          {:error, reason} -> {:error, {:child_specs_error, format_error(reason)}}
        end
      else
        {:ok, []}
      end

    with {:ok, list} <- specs do
      Enum.reduce_while(list, :ok, fn spec, :ok ->
        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, _pid} -> {:cont, :ok}
          {:ok, _pid, _info} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:child_start_failed, reason}}}
        end
      end)
    end
  end

  defp stop_all_children do
    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(@supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    :ok
  end

  defp smoke_test_render(mod) do
    if function_exported?(mod, :render, 1) do
      case Tools.run_isolated(fn -> mod.render(%{}) end, @smoke_timeout) do
        {:ok, html} when is_binary(html) -> :ok
        {:ok, other} -> {:error, {:invalid_render_return, other}}
        {:error, reason} -> {:error, {:render_error, format_error(reason)}}
      end
    else
      {:error, :missing_render_callback}
    end
  end

  defp safe_meta(mod) do
    default = %{name: inspect(mod), description: ""}

    if function_exported?(mod, :app_meta, 0) do
      case Tools.run_isolated(fn -> mod.app_meta() end, @smoke_timeout) do
        {:ok, %{} = meta} ->
          %{
            name: to_string(meta[:name] || meta["name"] || default.name),
            description: to_string(meta[:description] || meta["description"] || "")
          }

        _ ->
          default
      end
    else
      default
    end
  end

  defp broadcast_update(entry) do
    Session.broadcast("app_updated", %{
      version: entry.version,
      title: entry.meta.name,
      module: inspect(entry.module)
    })
  end

  defp format_error({%_{} = exception, _stack}), do: Exception.message(exception)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
