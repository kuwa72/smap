defmodule AgentLab.Definition do
  @moduledoc """
  Agent definition loaded from `agents/<name>.edn` (FR-1).

  The file is read on every `load/1` call, so swapping the EDN file yields a
  new definition without restarting the VM or the application.
  """

  @required_keys [:role, :prompt, :code_template, :tools, :evaluation]

  @enforce_keys [:name | @required_keys]
  defstruct [:name, :role, :prompt, :code_template, :tools, :evaluation]

  @type t :: %__MODULE__{
          name: String.t(),
          role: String.t(),
          prompt: String.t(),
          code_template: String.t(),
          tools: [String.t()],
          evaluation: [map()]
        }

  @doc "Load `agents/<name>.edn` and return the agent definition."
  @spec load(String.t() | atom()) :: {:ok, t()} | {:error, term()}
  def load(name) do
    path = Path.join(["agents", "#{name}.edn"])

    with {:ok, content} <- File.read(path),
         {:ok, data} <- parse_edn(content),
         :ok <- validate(data) do
      {:ok,
       struct!(__MODULE__, Map.merge(Map.take(data, @required_keys), %{name: to_string(name)}))}
    end
  end

  defp parse_edn(content) do
    case AgentLab.EDN.decode(content) do
      {:ok, data} when is_map(data) ->
        if Enum.all?(Map.keys(data), &is_atom/1) do
          {:ok, data}
        else
          {:error, :invalid_definition}
        end

      {:ok, _} ->
        {:error, :invalid_definition}

      {:error, _reason} ->
        {:error, :invalid_definition}
    end
  end

  defp validate(data) do
    missing = Enum.reject(@required_keys, &Map.has_key?(data, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_keys, missing}}
    end
  end
end
