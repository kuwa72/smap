defmodule AgentLab.VersionsTest do
  use ExUnit.Case

  @app :versions_test_app
  @agent :greeter

  setup do
    on_exit(fn ->
      File.rm(Path.join("evolution", "#{@app}.jsonl"))
    end)

    :ok
  end

  test "load compiles, loads and makes the version current" do
    source = """
    defmodule Greeter.V1 do
      def hi, do: :v1
    end
    """

    assert {:ok, mod} = AgentLab.Versions.load(@app, @agent, source)
    assert AgentLab.Versions.current(@app, @agent) == mod
    assert apply(mod, :hi, []) == :v1
    assert AgentLab.Versions.history(@app, @agent) == [mod]
  end

  test "new load appends version; rollback and activate switch the pointer" do
    {:ok, m1} =
      AgentLab.Versions.load(@app, :multi, """
      defmodule Multi.V1 do
        def hi, do: :v1
      end
      """)

    {:ok, m2} =
      AgentLab.Versions.load(@app, :multi, """
      defmodule Multi.V2 do
        def hi, do: :v2
      end
      """)

    assert AgentLab.Versions.current(@app, :multi) == m2
    assert apply(AgentLab.Versions.current(@app, :multi), :hi, []) == :v2
    assert AgentLab.Versions.history(@app, :multi) == [m1, m2]

    assert :ok = AgentLab.Versions.rollback(@app, :multi)
    assert AgentLab.Versions.current(@app, :multi) == m1
    assert apply(AgentLab.Versions.current(@app, :multi), :hi, []) == :v1

    assert :ok = AgentLab.Versions.activate(@app, :multi, m2)
    assert AgentLab.Versions.current(@app, :multi) == m2
  end

  test "rollback with a single version fails" do
    {:ok, _} =
      AgentLab.Versions.load(@app, :single, """
      defmodule Single.V1 do
        def hi, do: :v1
      end
      """)

    assert {:error, :no_previous_version} = AgentLab.Versions.rollback(@app, :single)
  end

  test "invalid source returns an error and keeps the current version" do
    {:ok, m1} =
      AgentLab.Versions.load(@app, :bad, """
      defmodule Bad.V1 do
        def hi, do: :v1
      end
      """)

    assert {:error, _} = AgentLab.Versions.load(@app, :bad, "defmodule {{{")
    assert AgentLab.Versions.current(@app, :bad) == m1
  end

  test "discard never lands current on a previously discarded version" do
    {:ok, a} =
      AgentLab.Versions.load(@app, :seq, """
      defmodule Seq.V1 do
        def hi, do: :v1
      end
      """)

    {:ok, _b} =
      AgentLab.Versions.load(@app, :seq, """
      defmodule Seq.V2 do
        def hi, do: :v2
      end
      """)

    assert :ok = AgentLab.Versions.discard(@app, :seq)
    assert AgentLab.Versions.current(@app, :seq) == a

    {:ok, _c} =
      AgentLab.Versions.load(@app, :seq, """
      defmodule Seq.V3 do
        def hi, do: :v3
      end
      """)

    assert :ok = AgentLab.Versions.discard(@app, :seq)
    assert AgentLab.Versions.current(@app, :seq) == a
  end

  test "record_score appends JSON lines to evolution/<app>.jsonl" do
    {:ok, m1} =
      AgentLab.Versions.load(@app, :scored, """
      defmodule Scored.V1 do
        def hi, do: :v1
      end
      """)

    assert :ok = AgentLab.Versions.record_score(@app, :scored, m1, 0.9, nil)

    records =
      Path.join("evolution", "#{@app}.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)

    assert Enum.any?(records, fn r ->
             r["type"] == "score" and r["score"] == 0.9 and r["version"] == Atom.to_string(m1)
           end)

    assert Enum.any?(records, &(&1["type"] == "load"))
  end
end
