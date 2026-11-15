defmodule AgentLab.DefinitionTest do
  use ExUnit.Case

  @dir Path.join(File.cwd!(), "agents")

  setup do
    File.mkdir_p!(@dir)

    on_exit(fn ->
      for file <- Path.wildcard(Path.join(@dir, "*_test.edn")) do
        File.rm(file)
      end
    end)

    :ok
  end

  defp write_edn!(name, content) do
    path = Path.join(@dir, "#{name}.edn")
    File.write!(path, content)
    path
  end

  test "load reads role, prompt, code_template, tools and evaluation from EDN" do
    write_edn!("full_test", """
    {:name "full"
     :role "greeter"
     :prompt "say hi"
     :code_template "defmodule X do end"
     :tools ["read_file" "write_file"]
     :evaluation [{:task "t1" :expect "hi"}]}
    """)

    assert {:ok, def} = AgentLab.Definition.load("full_test")
    assert def.name == "full_test"
    assert def.role == "greeter"
    assert def.prompt == "say hi"
    assert def.code_template == "defmodule X do end"
    assert def.tools == ["read_file", "write_file"]
    assert def.evaluation == [%{task: "t1", expect: "hi"}]
  end

  test "load returns a fresh definition when the file is replaced" do
    write_edn!("swap_test", """
    {:name "swap" :role "v1" :prompt "p" :code_template "c" :tools [] :evaluation []}
    """)

    assert {:ok, v1} = AgentLab.Definition.load("swap_test")
    assert v1.role == "v1"

    write_edn!("swap_test", """
    {:name "swap" :role "v2" :prompt "p2" :code_template "c2" :tools [] :evaluation []}
    """)

    assert {:ok, v2} = AgentLab.Definition.load("swap_test")
    assert v2.role == "v2"
    assert v2.prompt == "p2"
  end

  test "load fails when a required key is missing" do
    write_edn!("missing_test", """
    {:name "missing" :role "r" :prompt "p" :code_template "c" :tools []}
    """)

    assert {:error, {:missing_keys, keys}} = AgentLab.Definition.load("missing_test")
    assert :evaluation in keys
  end

  test "load fails when the file does not exist" do
    assert {:error, :enoent} = AgentLab.Definition.load("no_such_agent")
  end

  test "load fails when the file is not a map" do
    write_edn!("notmap_test", """
    [1 2 3]
    """)

    assert {:error, :invalid_definition} = AgentLab.Definition.load("notmap_test")
  end
end
