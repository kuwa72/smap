defmodule AgentLab.App do
  @moduledoc """
  App abstraction for self-modifying agent apps (FR-6).

  `use AgentLab.App` and implement the callbacks; the shared machinery —
  EDN definitions (FR-1), hot-loaded versions (FR-2), timeout-isolated
  evaluation (FR-3) and the adopt/discard gate — is driven by `setup/1`,
  `improve/3` and `run/3`.

  `propose` is a `current_version -> {:ok, source} | {:error, reason}` fun
  that supplies candidate code (LLM-backed once the FR-2 loop lands, stubbed
  in tests). Candidate sources must define a fresh module per version.
  """

  alias AgentLab.{Definition, Evaluator, Evolution, Versions}

  @callback agents() :: [String.t()]
  @callback tasks() :: [term()]
  @callback evaluate(module(), term()) :: number()

  defmacro __using__(_opts) do
    quote do
      @behaviour AgentLab.App

      def agents, do: []
      def tasks, do: []
      def evaluate(_agent, _task), do: 0.0

      defoverridable agents: 0, tasks: 0, evaluate: 2
    end
  end

  @doc "App key for `evolution/<app>.jsonl`, derived from the module name."
  @spec app_key(module()) :: atom()
  def app_key(app_mod) do
    app_mod |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
  end

  @doc """
  Load each agent's EDN definition and hot-load its `code_template` as the
  first version, recording the baseline score. Already-loaded agents keep
  their current version. Returns `{name, result}` pairs.
  """
  @spec setup(module()) :: [{String.t(), {:ok, module(), float()} | {:error, term()}}]
  def setup(app_mod) do
    app = app_key(app_mod)

    for name <- app_mod.agents() do
      {name, setup_agent(app_mod, app, name)}
    end
  end

  @doc """
  One self-improvement step for `name`: ask `propose` for new source,
  hot-load it, score it over `app_mod.tasks()` and let the adoption gate
  decide. Returns a result map.
  """
  @spec improve(module(), String.t(), (module() | nil -> {:ok, String.t()} | {:error, term()})) ::
          map()
  def improve(app_mod, name, propose) do
    app = app_key(app_mod)
    current = Versions.current(app, name)

    case propose.(current) do
      {:ok, source} ->
        with {:ok, version} <- Versions.load(app, name, source) do
          score = Evaluator.run(app_mod, version, app_mod.tasks())

          %{
            agent: name,
            version: version,
            score: score,
            decision: Evolution.maybe_adopt(app, name, version, score)
          }
        else
          {:error, reason} -> %{agent: name, error: reason}
        end

      {:error, reason} ->
        %{agent: name, error: reason}
    end
  end

  @doc "`setup/1` followed by `rounds` improvement steps per agent."
  @spec run(module(), (module() | nil -> {:ok, String.t()} | {:error, term()}), keyword()) :: [
          map()
        ]
  def run(app_mod, propose, opts \\ []) do
    rounds = Keyword.get(opts, :rounds, 1)
    setup(app_mod)

    for _ <- 1..rounds, name <- app_mod.agents() do
      improve(app_mod, name, propose)
    end
  end

  defp setup_agent(app_mod, app, name) do
    with {:ok, def} <- Definition.load(name),
         {:ok, version} <- ensure_loaded(app, name, def.code_template) do
      score = Evaluator.run(app_mod, version, app_mod.tasks())
      record_baseline(app, name, version, score)
      {:ok, version, score}
    else
      {:error, _} = error -> error
    end
  end

  defp ensure_loaded(app, name, source) do
    case Versions.current(app, name) do
      nil -> Versions.load(app, name, source)
      version -> {:ok, version}
    end
  end

  defp record_baseline(app, name, version, score) do
    if is_nil(Versions.score(app, name, version)) do
      _ = Versions.record_score(app, name, version, score, nil)
    end
  end
end
