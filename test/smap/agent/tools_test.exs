defmodule Smap.Agent.ToolsTest do
  use ExUnit.Case, async: false

  alias Smap.Agent.Tools
  alias Smap.AppSpace.Manager

  setup do
    Manager.reset()

    on_exit(fn ->
      Manager.reset()
      Application.delete_env(:smap, :allowed_file_roots)
    end)

    :ok
  end

  test "apply_app_update, read_app_code, inspect_runtime, and rollback_app work end-to-end" do
    v1 = """
    defmodule Smap.UserApp.ToolsV1 do
      use Smap.AppSpace.Behaviour
      def app_meta, do: %{name: "ToolsV1", description: "first"}
      def render(_), do: "<p>tools-v1</p>"
    end
    """

    v2 = """
    defmodule Smap.UserApp.ToolsV2 do
      use Smap.AppSpace.Behaviour
      def app_meta, do: %{name: "ToolsV2", description: "second"}
      def render(_), do: "<p>tools-v2</p>"
    end
    """

    assert %{ok: true, version: 1, title: "ToolsV1"} =
             Tools.execute("apply_app_update", %{"source" => v1})

    code_info = Tools.execute("read_app_code", %{})
    assert code_info.ok == true
    assert code_info.version == 1
    assert code_info.source =~ "tools-v1"

    runtime = Tools.execute("inspect_runtime", %{})
    assert runtime.ok == true
    assert runtime.status.current.version == 1

    assert %{ok: true, version: 2, title: "ToolsV2"} =
             Tools.execute("apply_app_update", %{"source" => v2})

    assert %{ok: true, version: 1, title: "ToolsV1"} = Tools.execute("rollback_app", %{})
  end

  test "list_local_files lists files inside allowed root and blocks path traversal" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "smap_tools_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, "track1.mp3"), "dummy")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Application.put_env(:smap, :allowed_file_roots, [tmp_dir])

    assert %{ok: true, entries: entries} = Tools.execute("list_local_files", %{"path" => tmp_dir})
    assert Enum.any?(entries, &(&1.name == "track1.mp3"))

    outside = Path.expand("..", tmp_dir)
    assert %{ok: false, error: _} = Tools.execute("list_local_files", %{"path" => outside})

    link_path = Path.join(tmp_dir, "escape_link")
    File.ln_s!(outside, link_path)
    assert %{ok: false, error: _} = Tools.execute("list_local_files", %{"path" => link_path})
  end
end
