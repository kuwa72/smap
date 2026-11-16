defmodule AgentLab.LLMTest do
  use ExUnit.Case

  alias AgentLab.LLM

  setup do
    keys = ~w(COMMANDCODE_API_KEY COMMANDCODE_BASE_URL COMMANDCODE_MODEL)

    on_exit(fn ->
      Enum.each(keys, &System.delete_env/1)
    end)

    :ok
  end

  test "config/0 reads provider settings from the environment" do
    System.put_env("COMMANDCODE_API_KEY", "test-key")
    System.put_env("COMMANDCODE_BASE_URL", "https://llm.example.com/v1")
    System.put_env("COMMANDCODE_MODEL", "deepseek-test")

    assert LLM.config() == %{
             api_key: "test-key",
             base_url: "https://llm.example.com/v1",
             model: "deepseek-test"
           }
  end

  test "config/0 falls back to the default model" do
    System.delete_env("COMMANDCODE_MODEL")

    assert LLM.config().model == "deepseek/deepseek-v4.1-flash"
  end
end
