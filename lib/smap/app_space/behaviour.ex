defmodule Smap.AppSpace.Behaviour do
  @moduledoc """
  Contract implemented by dynamically generated user application modules
  loaded into `Smap.AppSpace`.
  """

  @type meta :: %{name: String.t(), description: String.t()}
  @type response ::
          {:ok, pos_integer(), [{String.t(), String.t()}], iodata()}
          | {:file, Path.t(), String.t()}

  @callback app_meta() :: meta()
  @callback child_specs() :: [Supervisor.child_spec() | module() | {module(), term()}]
  @callback render(state :: map()) :: String.t()
  @callback handle_request(method :: String.t(), path :: [String.t()], params :: map()) ::
              response()

  @optional_callbacks app_meta: 0, child_specs: 0, handle_request: 3

  defmacro __using__(_opts) do
    quote do
      @behaviour Smap.AppSpace.Behaviour

      @impl true
      def app_meta, do: %{name: "UserApp", description: ""}

      @impl true
      def child_specs, do: []

      @impl true
      def handle_request(_method, _path, _params) do
        {:ok, 404, [{"content-type", "application/json"}], ~s({"error":"not_found"})}
      end

      defoverridable app_meta: 0, child_specs: 0, handle_request: 3
    end
  end
end
