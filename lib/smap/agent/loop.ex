defmodule Smap.Agent.Loop do
  @moduledoc """
  Resident self-modification agent loop (Core).

  Receives natural-language instructions from `Smap.Chat.Session`, inspects the
  current `Smap.AppSpace` state, invokes tools (`apply_app_update`,
  `read_app_code`, `rollback_app`, `inspect_runtime`, `list_local_files`) in a
  bounded loop with a strict overall deadline, feeds back compile/runtime
  errors for automatic self-correction, and returns a user-facing reply.
  """

  use GenServer

  alias AgentLab.{LLM, Tools}
  alias Smap.Agent.Tools, as: AgentTools
  alias Smap.AppSpace.Manager

  @default_max_steps 6
  @default_timeout 150_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run one interactive turn of the self-modifying agent loop."
  @spec respond(String.t(), [map()], keyword()) ::
          {:ok, String.t(), %{steps: [map()]}} | {:error, term()}
  def respond(content, history \\ [], opts \\ []) when is_binary(content) do
    timeout =
      Keyword.get_lazy(opts, :timeout, fn ->
        Application.get_env(:smap, :agent_timeout, @default_timeout)
      end)

    GenServer.call(__MODULE__, {:respond, content, history, opts, timeout}, timeout + 15_000)
  end

  @doc "Return the tool steps recorded during the last turn."
  @spec last_steps() :: [map()]
  def last_steps do
    GenServer.call(__MODULE__, :last_steps)
  end

  @impl true
  def init(_opts) do
    {:ok, %{last_steps: []}}
  end

  @impl true
  def handle_call(:last_steps, _from, state) do
    {:reply, state.last_steps, state}
  end

  def handle_call({:respond, content, history, opts, timeout}, _from, state) do
    max_steps =
      Keyword.get_lazy(opts, :max_steps, fn ->
        Application.get_env(:smap, :agent_max_steps, @default_max_steps)
      end)

    deadline = System.monotonic_time(:millisecond) + timeout
    messages = build_initial_messages(content, history)

    case run_loop(messages, [], max_steps, deadline) do
      {:ok, reply, steps} ->
        {:reply, {:ok, reply, %{steps: steps}}, %{state | last_steps: steps}}

      {:error, reason, steps} ->
        {:reply, {:error, reason}, %{state | last_steps: steps}}
    end
  end

  # --- loop ---

  defp run_loop(_messages, steps, 0, _deadline) do
    {:ok, "自己改修の最大試行回数上限に達しました。現在の安定バージョンは維持されています。指示を具体化して再度お試しください。", Enum.reverse(steps)}
  end

  defp run_loop(messages, steps, remaining, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :timeout, Enum.reverse(steps)}
    else
      case chat_with_timeout(messages, remaining_ms) do
        {:ok, raw_reply} ->
          case parse_action(raw_reply) do
            {:tool, tool_name, args} ->
              result = AgentTools.execute(tool_name, args)
              step_record = %{tool: tool_name, args: args, result: result}
              result_json = :json.encode(result) |> IO.iodata_to_binary()

              next_messages =
                messages ++
                  [
                    %{role: "assistant", content: raw_reply},
                    %{
                      role: "user",
                      content:
                        "Tool result (#{tool_name}): #{result_json}\n" <>
                          "If it failed, fix the code and retry with apply_app_update. If done, return {\"action\":\"reply\",\"message\":\"...\"}."
                    }
                  ]

              run_loop(next_messages, [step_record | steps], remaining - 1, deadline)

            {:reply, message} ->
              {:ok, message, Enum.reverse(steps)}
          end

        {:error, reason} ->
          {:error, reason, Enum.reverse(steps)}
      end
    end
  end

  # --- prompt & parsing ---

  defp build_initial_messages(content, history) do
    system_prompt = build_system_prompt()

    trimmed_history =
      case List.last(history) do
        %{role: "user", content: ^content} -> Enum.drop(history, -1)
        %{"role" => "user", "content" => ^content} -> Enum.drop(history, -1)
        _ -> history
      end

    recent_history =
      trimmed_history
      |> Enum.take(-10)
      |> Enum.map(fn msg ->
        %{
          role: to_string(msg[:role] || msg["role"]),
          content: to_string(msg[:content] || msg["content"])
        }
      end)

    [%{role: "system", content: system_prompt}] ++
      recent_history ++ [%{role: "user", content: content}]
  end

  defp build_system_prompt do
    current = Manager.current()
    runtime = Manager.status()
    tools_json = :json.encode(AgentTools.definitions()) |> IO.iodata_to_binary()

    current_section =
      case current do
        nil ->
          "Current app: none (placeholder is shown)."

        entry ->
          """
          Current app:
          - Version: #{entry.version}
          - Module: #{inspect(entry.module)}
          - Name: #{entry.meta.name}
          - Source:
          ```elixir
          #{entry.source}
          ```
          """
      end

    """
    You are the embedded self-modifying AI agent inside Smap (Elixir/OTP on BEAM).
    Your job is to transform and continuously evolve the live application inside `Smap.AppSpace` without stopping the process.

    ## App Contract (`Smap.AppSpace.Behaviour`)
    - Every `defmodule` MUST be under the `Smap.UserApp.*` namespace (e.g. `Smap.UserApp.App`).
    - Include `use Smap.AppSpace.Behaviour`.
    - Implement `app_meta/0` returning `%{name: "...", description: "..."}`.
    - Implement `render/1` returning an HTML/CSS/JS string rendered in `#app-slot`.
    - Optionally implement `child_specs/0` (for GenServer/Agent state) and `handle_request/3` for `/app/*` HTTP routes.
    - Never call `System.halt`, `:init.stop`, `:os.cmd`, `apply`, or modify core modules.

    ## Current App Space State
    #{current_section}
    Last error: #{inspect(runtime.last_error)}

    ## Available Tools
    #{tools_json}

    ## Response Format (STRICT JSON ONLY)
    Always respond with a single JSON object (no extra text outside JSON):
    - To invoke a tool:
      {"action": "tool", "tool": "<tool_name>", "args": {...}}
    - To reply to the user when finished:
      {"action": "reply", "message": "日本語での簡潔な説明"}
    """
  end

  defp parse_action(raw) when is_binary(raw) do
    with {:ok, json} <- extract_json(raw),
         {:ok, decoded} <- decode_json(json) do
      case decoded do
        %{"action" => "tool", "tool" => tool} when is_binary(tool) ->
          args = if is_map(decoded["args"]), do: decoded["args"], else: %{}
          {:tool, tool, args}

        %{"action" => "reply", "message" => msg} when is_binary(msg) ->
          {:reply, msg}

        _ ->
          {:reply, String.trim(raw)}
      end
    else
      _ -> {:reply, String.trim(raw)}
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/```(?:json)?\s*\n(.*?)```/s, text) do
      [_, json] ->
        {:ok, json}

      _ ->
        case Regex.run(~r/\{.*\}/s, text) do
          [json] -> {:ok, json}
          _ -> {:error, :no_json}
        end
    end
  end

  defp decode_json(json) do
    try do
      {:ok, :json.decode(json)}
    rescue
      _ -> {:error, :invalid_json}
    end
  end

  defp chat_with_timeout(messages, remaining_ms) do
    fun = Application.get_env(:smap, :agent_chat, &LLM.chat/1)

    case Tools.run_isolated(fn -> fun.(messages) end, remaining_ms) do
      {:ok, {:ok, text}} when is_binary(text) -> {:ok, text}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_llm_reply, other}}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end
end
