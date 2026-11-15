defmodule AgentLab.LLM do
  @moduledoc """
  LLM access via `req_llm` (FR-5).

  The provider is an OpenAI-compatible endpoint (CommandCode DeepSeek V4.1
  Flash). Connection settings come from the environment; a `.env` file in the
  project root is used as a fallback and is gitignored:

      COMMANDCODE_API_KEY=...
      COMMANDCODE_BASE_URL=https://api.commandcode.ai/provider/v1
      COMMANDCODE_MODEL=deepseek/deepseek-v4.1-flash
  """

  @type config :: %{model: String.t(), base_url: String.t() | nil, api_key: String.t() | nil}

  @doc "Provider configuration from env vars / `.env`."
  @spec config() :: config()
  def config do
    %{
      model: env("COMMANDCODE_MODEL") || "deepseek/deepseek-v4.1-flash",
      base_url: env("COMMANDCODE_BASE_URL"),
      api_key: env("COMMANDCODE_API_KEY")
    }
  end

  @doc "Send `prompt` (string or message list) and return the text reply."
  @spec chat(String.t() | [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(prompt, opts \\ []) do
    config = config()

    req_opts =
      [api_key: config.api_key, base_url: config.base_url]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Keyword.merge(opts)

    try do
      {:ok, ReqLLM.generate_text!(model_spec(config), to_messages(prompt), req_opts)}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp model_spec(%{model: model, base_url: base_url}) do
    spec = %{provider: :openai, id: model}
    if base_url, do: Map.put(spec, :base_url, base_url), else: spec
  end

  defp to_messages(prompt) when is_binary(prompt), do: [%{role: "user", content: prompt}]

  defp to_messages(messages) when is_list(messages),
    do: Enum.map(messages, &normalize_message/1)

  defp normalize_message(%{} = msg) do
    %{
      role: msg[:role] || msg["role"],
      content: msg[:content] || msg["content"]
    }
  end

  defp env(key) do
    System.get_env(key) || dotenv()[key]
  end

  defp dotenv do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      %{}
    else
      read_dotenv()
    end
  end

  defp read_dotenv do
    case File.read(".env") do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, "=", parts: 2) do
            [k, v] ->
              k = String.trim(k)

              if k == "" or String.starts_with?(k, "#") do
                acc
              else
                Map.put(acc, k, String.trim(v))
              end

            _ ->
              acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end
end
