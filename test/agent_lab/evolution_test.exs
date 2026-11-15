defmodule AgentLab.EvolutionTest do
  use ExUnit.Case

  alias AgentLab.{Evolution, Versions}

  @app :evolution_test_app

  setup do
    on_exit(fn ->
      File.rm(Path.join("evolution", "#{@app}.jsonl"))
    end)

    :ok
  end

  defp src(mod, fun) do
    """
    defmodule #{mod} do
      def hi, do: #{fun}
    end
    """
  end

  defp chat_returning(source) do
    fn _messages -> {:ok, "```elixir\n#{source}\n```"} end
  end

  test "step adopts the first proposal and returns the result" do
    {:ok, res} =
      Evolution.step(@app, :adopted_agent,
        prompt: "improve",
        chat: chat_returning(src("EvoFirst.V1", ":first")),
        evaluate: fn _agent, _version -> 0.9 end
      )

    assert res.decision == :adopted
    assert res.score == 0.9
    assert res.version == Versions.current(@app, :adopted_agent)
    assert apply(res.version, :hi, []) == :first
  end

  test "step discards a proposal whose score does not beat the current version" do
    {:ok, _} =
      Evolution.step(@app, :discard_agent,
        prompt: "improve",
        chat: chat_returning(src("EvoKeep.V1", ":v1")),
        evaluate: fn _agent, _version -> 0.8 end
      )

    {:ok, res} =
      Evolution.step(@app, :discard_agent,
        prompt: "improve",
        chat: chat_returning(src("EvoKeep.V2", ":v2")),
        evaluate: fn _agent, _version -> 0.5 end
      )

    assert res.decision == :discarded
    assert res.score == 0.5
    assert res.previous_version != nil
    assert apply(Versions.current(@app, :discard_agent), :hi, []) == :v1
    assert length(Versions.history(@app, :discard_agent)) == 2
  end

  test "step discards a proposal with an equal score" do
    {:ok, _} =
      Evolution.step(@app, :tie,
        prompt: "improve",
        chat: chat_returning(src("EvoTie.V1", ":v1")),
        evaluate: fn _agent, _version -> 0.5 end
      )

    {:ok, res} =
      Evolution.step(@app, :tie,
        prompt: "improve",
        chat: chat_returning(src("EvoTie.V2", ":v2")),
        evaluate: fn _agent, _version -> 0.5 end
      )

    assert res.decision == :discarded
    assert apply(Versions.current(@app, :tie), :hi, []) == :v1
  end

  test "step returns an error when the LLM call fails" do
    assert {:error, :boom} =
             Evolution.step(@app, :llm_fail,
               prompt: "improve",
               chat: fn _messages -> {:error, :boom} end,
               evaluate: fn _agent, _version -> 1.0 end
             )
  end

  test "step returns an error on uncompilable source and keeps the current version" do
    {:ok, m1} =
      Evolution.step(@app, :bad_src,
        prompt: "improve",
        chat: chat_returning(src("EvoBad.V1", ":v1")),
        evaluate: fn _agent, _version -> 0.5 end
      )
      |> then(fn {:ok, res} -> {:ok, res.version} end)

    assert {:error, _} =
             Evolution.step(@app, :bad_src,
               prompt: "improve",
               chat: fn _messages -> {:ok, "defmodule {{{"} end,
               evaluate: fn _agent, _version -> 1.0 end
             )

    assert Versions.current(@app, :bad_src) == m1
  end

  test "step discards the loaded version when evaluation fails" do
    {:ok, _} =
      Evolution.step(@app, :eval_fail,
        prompt: "improve",
        chat: chat_returning(src("EvoEval.V1", ":v1")),
        evaluate: fn _agent, _version -> 0.5 end
      )

    {:ok, res} =
      Evolution.step(@app, :eval_fail,
        prompt: "improve",
        chat: chat_returning(src("EvoEval.V2", ":v2")),
        evaluate: fn _agent, _version -> {:error, :no_score} end
      )

    assert res.decision == :discarded
    assert res.error == :no_score
    assert apply(Versions.current(@app, :eval_fail), :hi, []) == :v1
  end

  test "step accepts an arity-1 evaluator and messages input" do
    messages = [%{role: "user", content: "improve"}]

    {:ok, res} =
      Evolution.step(@app, :arity1,
        messages: messages,
        chat: fn _messages -> {:ok, src("EvoArity.V1", ":ok")} end,
        evaluate: fn _version -> {:ok, 0.7} end
      )

    assert res.decision == :adopted
    assert res.score == 0.7
  end
end
