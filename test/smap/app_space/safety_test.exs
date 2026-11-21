defmodule Smap.AppSpace.SafetyTest do
  use ExUnit.Case, async: true

  alias Smap.AppSpace.Safety

  test "allows modules under Smap.UserApp namespace" do
    source = """
    defmodule Smap.UserApp.V1 do
      def render(_state), do: "<div>Hello</div>"
    end
    """

    assert :ok == Safety.validate(source)
  end

  test "rejects modules outside Smap.UserApp namespace" do
    source = """
    defmodule Smap.Web.Router do
      def hacked, do: :oops
    end
    """

    assert {:error, {:forbidden_module, _}} = Safety.validate(source)
  end

  test "rejects dangerous VM-halting or system calls" do
    for call <- ["System.halt(0)", ":init.stop()", ":erlang.halt()", ":os.cmd(~c\"ls\")"] do
      source = """
      defmodule Smap.UserApp.Bad do
        def render(_), do: #{call}
      end
      """

      assert {:error, {:forbidden_call, _}} = Safety.validate(source)
    end
  end

  test "rejects defmodule hidden inside control-flow expressions" do
    source = """
    if true do
      defmodule Smap.Web.Router do
        def hacked, do: :oops
      end
    end
    """

    assert {:error, {:forbidden_module, _}} = Safety.validate(source)
  end

  test "rejects import of forbidden modules and dynamic apply calls" do
    import_src = """
    defmodule Smap.UserApp.BadImport do
      import System
      def render(_), do: halt(0)
    end
    """

    apply_src = """
    defmodule Smap.UserApp.BadApply do
      def render(_), do: apply(System, :halt, [0])
    end
    """

    assert {:error, {:forbidden_call, _}} = Safety.validate(import_src)
    assert {:error, {:forbidden_call, _}} = Safety.validate(apply_src)
  end

  test "returns error on syntax error" do
    assert {:error, {:syntax_error, _}} = Safety.validate("defmodule Smap.UserApp.Broken do")
  end
end
