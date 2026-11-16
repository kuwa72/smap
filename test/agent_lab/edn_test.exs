defmodule AgentLab.EDNTest do
  use ExUnit.Case

  alias AgentLab.EDN

  test "encode/decode round-trips a definition-shaped map" do
    def = %{
      name: "doubling",
      role: "math",
      prompt: "double the input\nwith \"quotes\"",
      code_template: "defmodule X.V0 do\n  def solve(x), do: x * 2\nend",
      tools: [],
      evaluation: [%{input: 1, expect: 2}, %{input: 2, expect: 4}]
    }

    assert {:ok, ^def} = EDN.decode(EDN.encode(def))
  end

  test "encode/decode round-trips non-ASCII strings" do
    def = %{name: "doubling", prompt: "こんにちは \"世界\"\n二行目"}
    assert {:ok, ^def} = EDN.decode(EDN.encode(def))
  end

  test "encode escapes strings the decoder accepts" do
    text = ~S({:prompt "a\"b\\c\nd"})
    assert {:ok, %{:prompt => "a\"b\\c\nd"}} = EDN.decode(text)
  end
end
