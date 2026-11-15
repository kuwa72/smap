defmodule AgentLab.EvaluatorTest do
  use ExUnit.Case

  @app :evaluator_test_app

  defmodule GoodApp do
    def evaluate(_agent, %{score: score}), do: score
  end

  defmodule SlowApp do
    def evaluate(_agent, :slow), do: Process.sleep(10_000)
    def evaluate(_agent, score), do: score
  end

  defmodule BoomApp do
    def evaluate(_agent, :boom), do: raise("boom")
    def evaluate(_agent, score), do: score
  end

  setup do
    on_exit(fn -> File.rm(Path.join("evolution", "#{@app}.jsonl")) end)

    :ok
  end

  test "run/3 scores tasks via app.evaluate/2 and returns the mean" do
    tasks = [%{score: 1.0}, %{score: 0.0}, %{score: 0.5}]
    assert_in_delta AgentLab.Evaluator.run(GoodApp, :agent, tasks), 0.5, 0.0001
  end

  test "run/3 isolates timeouts: slow task scores 0, others still count" do
    tasks = [:slow, 1.0]

    assert_in_delta AgentLab.Evaluator.run(SlowApp, :agent, tasks, timeout: 50), 0.5, 0.0001
  end

  test "run/3 isolates exceptions: failing task scores 0, evaluation survives" do
    tasks = [:boom, 1.0]
    assert_in_delta AgentLab.Evaluator.run(BoomApp, :agent, tasks), 0.5, 0.0001
  end

  test "run/3 on empty tasks returns 0.0" do
    assert AgentLab.Evaluator.run(GoodApp, :agent, []) == 0.0
  end

  test "maybe_adopt activates and records score only when new score is higher" do
    {:ok, m1} =
      AgentLab.Versions.load(@app, :adopt, """
      defmodule Adopt.V1 do
        def v, do: 1
      end
      """)

    :ok = AgentLab.Versions.record_score(@app, :adopt, m1, 0.5, nil)

    {:ok, m2} =
      AgentLab.Versions.load(@app, :adopt, """
      defmodule Adopt.V2 do
        def v, do: 2
      end
      """)

    assert :adopted = AgentLab.Evolution.maybe_adopt(@app, :adopt, m2, 0.8)
    assert AgentLab.Versions.current(@app, :adopt) == m2

    records = score_records(@app)
    assert Enum.any?(records, &(&1["version"] == Atom.to_string(m2) and &1["score"] == 0.8))
    assert Enum.any?(records, &(&1["version"] == Atom.to_string(m1) and &1["score"] == 0.5))
  end

  test "maybe_adopt discards when new score does not beat current" do
    {:ok, m1} =
      AgentLab.Versions.load(@app, :reject, """
      defmodule Reject.V1 do
        def v, do: 1
      end
      """)

    :ok = AgentLab.Versions.record_score(@app, :reject, m1, 0.5, nil)

    {:ok, m2} =
      AgentLab.Versions.load(@app, :reject, """
      defmodule Reject.V2 do
        def v, do: 2
      end
      """)

    before = length(score_records(@app))

    assert :rejected = AgentLab.Evolution.maybe_adopt(@app, :reject, m2, 0.4)
    assert AgentLab.Versions.current(@app, :reject) == m1
    assert length(score_records(@app)) == before
  end

  test "maybe_adopt rejecting the incumbent keeps the pointer in place" do
    {:ok, m1} =
      AgentLab.Versions.load(@app, :incumbent, """
      defmodule Incumbent.V1 do
        def v, do: 1
      end
      """)

    {:ok, m2} =
      AgentLab.Versions.load(@app, :incumbent, """
      defmodule Incumbent.V2 do
        def v, do: 2
      end
      """)

    :ok = AgentLab.Versions.record_score(@app, :incumbent, m2, 0.8, m1)

    assert :rejected = AgentLab.Evolution.maybe_adopt(@app, :incumbent, m2, 0.7)
    assert AgentLab.Versions.current(@app, :incumbent) == m2
  end

  test "maybe_adopt compares against the current version's score, not the last recorded" do
    {:ok, m1} =
      AgentLab.Versions.load(@app, :baseline, """
      defmodule Baseline.V1 do
        def v, do: 1
      end
      """)

    {:ok, m2} =
      AgentLab.Versions.load(@app, :baseline, """
      defmodule Baseline.V2 do
        def v, do: 2
      end
      """)

    {:ok, m3} =
      AgentLab.Versions.load(@app, :baseline, """
      defmodule Baseline.V3 do
        def v, do: 3
      end
      """)

    :ok = AgentLab.Versions.record_score(@app, :baseline, m3, 0.7, m2)
    :ok = AgentLab.Versions.record_score(@app, :baseline, m1, 0.9, nil)

    {:ok, m4} =
      AgentLab.Versions.load(@app, :baseline, """
      defmodule Baseline.V4 do
        def v, do: 4
      end
      """)

    assert :adopted = AgentLab.Evolution.maybe_adopt(@app, :baseline, m4, 0.8)
    assert AgentLab.Versions.current(@app, :baseline) == m4
  end

  test "adopt?/2 is a strict greater-than comparison" do
    assert AgentLab.Evolution.adopt?(0.6, 0.5)
    refute AgentLab.Evolution.adopt?(0.5, 0.5)
    refute AgentLab.Evolution.adopt?(0.4, 0.5)
  end

  defp score_records(app) do
    path = Path.join("evolution", "#{app}.jsonl")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)
      |> Enum.filter(&(&1["type"] == "score"))
    else
      []
    end
  end
end
