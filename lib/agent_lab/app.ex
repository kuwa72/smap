defmodule AgentLab.App do
  @moduledoc """
  Behaviour for AgentLab applications (FR-6).

  An app module does `use AgentLab.App` and implements:

    * `agents/0` — the agent roles the app coordinates
    * `tasks/0` — the task set used for evaluation (defaults to `[]`)
    * `evaluate/2` — app-specific judgement of a result (defaults to `:ok`)

  The shared AgentLab machinery (transport, versions, evolution) is provided
  by the runtime; the app only declares its roles and judgement.
  """

  @callback agents() :: [term()]
  @callback tasks() :: [term()]
  @callback evaluate(term(), term()) :: term()

  defmacro __using__(_opts) do
    quote do
      @behaviour AgentLab.App

      def tasks, do: []
      def evaluate(_result, _context), do: :ok

      defoverridable tasks: 0, evaluate: 2
    end
  end
end
