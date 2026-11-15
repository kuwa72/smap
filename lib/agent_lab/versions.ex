defmodule AgentLab.Versions do
  @moduledoc """
  Hot-loads agent code as versioned modules and keeps a switchable pointer
  per `{app, agent}` (FR-2).

  `source` is Elixir source that defines one or more modules; every module is
  compiled and loaded with `:code.load_binary/3`. The *first* module defined in
  the source is recorded as the agent's current version.
  """

  use GenServer

  @table :agentlab_versions
  @scores_table :agentlab_scores

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Compile and load `source`; the new version becomes current."
  @spec load(atom(), atom(), String.t()) :: {:ok, module()} | {:error, term()}
  def load(app, agent, source) do
    GenServer.call(__MODULE__, {:load, app, agent, source})
  end

  @doc "Current version module for `{app, agent}`, or nil."
  @spec current(atom(), atom()) :: module() | nil
  def current(app, agent) do
    case :ets.lookup(@table, {app, agent}) do
      [{_, %{versions: versions, current: idx}}] -> Enum.at(versions, idx)
      [] -> nil
    end
  end

  @doc "Score recorded for `version`, or nil."
  @spec score(atom(), atom(), module()) :: number() | nil
  def score(app, agent, version) do
    case :ets.lookup(@scores_table, {app, agent}) do
      [{_, %{by_version: by_version}}] -> Map.get(by_version, version)
      [] -> nil
    end
  end

  @doc "Score of the current version, or nil."
  @spec current_score(atom(), atom()) :: number() | nil
  def current_score(app, agent) do
    case current(app, agent) do
      nil -> nil
      version -> score(app, agent, version)
    end
  end

  @doc "All loaded versions, oldest first."
  @spec history(atom(), atom()) :: [module()]
  def history(app, agent) do
    case :ets.lookup(@table, {app, agent}) do
      [{_, %{versions: versions}}] -> versions
      [] -> []
    end
  end

  @doc "Version that was current before the latest pointer move, or nil."
  @spec previous(atom(), atom()) :: module() | nil
  def previous(app, agent) do
    case :ets.lookup(@table, {app, agent}) do
      [{_, %{versions: versions, previous: idx}}] when is_integer(idx) ->
        Enum.at(versions, idx)

      _ ->
        nil
    end
  end

  @doc "Point current back to the previous version."
  @spec rollback(atom(), atom()) :: :ok | {:error, :no_previous_version}
  def rollback(app, agent) do
    GenServer.call(__MODULE__, {:rollback, app, agent})
  end

  @doc "Point current at a previously loaded version."
  @spec activate(atom(), atom(), module()) :: :ok | {:error, :unknown_version}
  def activate(app, agent, module) do
    GenServer.call(__MODULE__, {:activate, app, agent, module})
  end

  @doc "Append a score record to `evolution/<app>.jsonl` (FR-2 audit log)."
  @spec record_score(atom(), atom(), module(), number() | nil, module() | nil) ::
          :ok | {:error, term()}
  def record_score(app, agent, version, score, parent) do
    case record(app, agent, %{
           type: "score",
           version: Atom.to_string(version),
           score: score,
           parent: parent && Atom.to_string(parent),
           ts: DateTime.utc_now() |> DateTime.to_iso8601()
         }) do
      :ok ->
        record_score_in_ets(app, agent, version, score)

      {:error, _} = error ->
        error
    end
  end

  defp record(app, _agent, map) do
    File.mkdir_p!("evolution")

    line =
      map
      |> Map.put(:app, Atom.to_string(app))
      |> :json.encode()
      |> IO.iodata_to_binary()
      |> Kernel.<>("\n")

    case File.open(Path.join("evolution", "#{app}.jsonl"), [:append]) do
      {:ok, io} ->
        IO.binwrite(io, line)
        File.close(io)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_score_in_ets(app, agent, version, score) do
    key = {app, agent}

    by_version =
      case :ets.lookup(@scores_table, key) do
        [{^key, %{by_version: scores}}] -> Map.put(scores, version, score)
        _ -> %{version => score}
      end

    :ets.insert(@scores_table, {key, %{by_version: by_version}})
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.new(@scores_table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, app, agent, source}, _from, state) do
    key = {app, agent}
    parent = current(app, agent)

    case compile_and_load(source) do
      {:ok, module} ->
        {versions, idx, prev} =
          case :ets.lookup(@table, key) do
            [{_, entry}] ->
              versions = Map.get(entry, :versions, [])
              {versions ++ [module], length(versions), Map.get(entry, :current)}

            [] ->
              {[module], 0, nil}
          end

        :ets.insert(@table, {key, %{versions: versions, current: idx, previous: prev}})

        record(app, agent, %{
          type: "load",
          version: Atom.to_string(module),
          parent: parent && Atom.to_string(parent),
          ts: DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:reply, {:ok, module}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rollback, app, agent}, _from, state) do
    key = {app, agent}

    reply =
      case :ets.lookup(@table, key) do
        [{_, %{versions: versions, current: idx}}] when idx > 0 ->
          :ets.insert(@table, {key, %{versions: versions, current: idx - 1, previous: idx}})
          :ok

        _ ->
          {:error, :no_previous_version}
      end

    {:reply, reply, state}
  end

  def handle_call({:activate, app, agent, module}, _from, state) do
    key = {app, agent}

    reply =
      case :ets.lookup(@table, key) do
        [{_, %{versions: versions} = entry}] ->
          case Enum.find_index(versions, &(&1 == module)) do
            nil ->
              {:error, :unknown_version}

            idx ->
              case Map.get(entry, :current) do
                ^idx ->
                  :ok

                current ->
                  :ets.insert(
                    @table,
                    {key, %{versions: versions, current: idx, previous: current}}
                  )

                  :ok
              end
          end

        [] ->
          {:error, :unknown_version}
      end

    {:reply, reply, state}
  end

  defp compile_and_load(source) do
    modules =
      try do
        Code.compile_string(source)
      rescue
        e -> {:error, Exception.message(e)}
      end

    case modules do
      [{_, _} | _] = compiled ->
        Enum.each(compiled, fn {mod, bin} -> :code.load_binary(mod, ~c"nofile", bin) end)
        {:ok, elem(hd(compiled), 0)}

      [] ->
        {:error, :no_modules_compiled}

      {:error, msg} ->
        {:error, msg}
    end
  end
end
