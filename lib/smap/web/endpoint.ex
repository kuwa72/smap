defmodule Smap.Web.Endpoint do
  @moduledoc """
  Supervises the local Bandit HTTP server bound to `127.0.0.1`.

  Defaults to port `0` (OS-assigned ephemeral port) so multiple Smap instances
  can coexist on the same machine without port conflicts. Override with the
  `SMAP_PORT` environment variable or `Application.put_env(:smap, :web_port, port)`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get_lazy(opts, :port, &configured_port/0)

    children = [
      {Bandit, plug: Smap.Web.Router, ip: {127, 0, 0, 1}, port: port, startup_log: false}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Return the actual TCP port the local HTTP server is listening on."
  @spec port() :: pos_integer()
  def port do
    [{_id, pid, _type, _modules}] = Supervisor.which_children(__MODULE__)
    {:ok, {_ip, actual_port}} = ThousandIsland.listener_info(pid)
    actual_port
  end

  @doc "Return the local base URL (e.g. `http://127.0.0.1:54321`)."
  @spec url() :: String.t()
  def url do
    "http://127.0.0.1:#{port()}"
  end

  defp configured_port do
    case System.get_env("SMAP_PORT") do
      nil ->
        Application.get_env(:smap, :web_port, 0)

      raw ->
        case Integer.parse(raw) do
          {port, ""} when port >= 0 and port <= 65_535 -> port
          _ -> Application.get_env(:smap, :web_port, 0)
        end
    end
  end
end
