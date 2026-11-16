# Smap

Self-modifying multi-agent architecture on Elixir/BEAM.

## LLM provider setup (FR-5)

LLM access goes through `AgentLab.LLM` (`req_llm`), targeting the
OpenAI-compatible CommandCode DeepSeek V4.1 Flash endpoint. Credentials are
read from the environment only — put them in `.env` (gitignored) or export
them:

```sh
COMMANDCODE_API_KEY=...
COMMANDCODE_BASE_URL=https://.../v1
COMMANDCODE_MODEL=deepseek-v4.1-flash   # optional, this is the default
```

### Verifying against the real API

```sh
mix deps.get
# fill in .env, then:
mix run -e '
  {:ok, res} = AgentLab.Evolution.step(:smap, :demo,
    prompt: "Return Elixir source defining defmodule Demo.V1 with def hi, do: :hi",
    evaluate: fn _agent, mod -> if apply(mod, :hi, []) == :hi, do: 1.0, else: 0.0 end)
  IO.inspect(res)
'
```

Expected: `decision: :adopted` and a `load`/`score` record appended to
`evolution/smap.jsonl`. Tests stub the LLM (`:chat` option), so `mix test`
needs no network or API key.

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `smap` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:smap, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/smap>.

