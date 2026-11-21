defmodule Smap.AppSpace.Safety do
  @moduledoc """
  AST-level safety checks run before compiling user-generated application code.

  Guards against two BEAM-specific risks:
  1. Overwriting core modules: every `defmodule` must resolve under `Smap.UserApp.*`.
  2. VM-halting / destructive system calls: `System.halt`, `:init.stop`,
     `:erlang.halt`, `:os.cmd`, direct `:code` manipulation, etc.
  """

  @forbidden_calls MapSet.new([
                     {System, :halt},
                     {System, :stop},
                     {:init, :stop},
                     {:init, :restart},
                     {:erlang, :halt},
                     {:os, :cmd},
                     {:code, :load_binary},
                     {:code, :delete},
                     {:code, :purge},
                     {:code, :soft_purge}
                   ])

  @doc "Validate Elixir source code before compilation."
  @spec validate(String.t()) :: :ok | {:error, term()}
  def validate(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        with :ok <- check_modules(ast, []),
             :ok <- check_calls(ast) do
          :ok
        end

      {:error, reason} ->
        {:error, {:syntax_error, reason}}
    end
  end

  defp check_modules(ast, prefix) do
    case ast do
      {:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]} ->
        full_parts = resolve_parts(prefix, parts)

        if allowed_namespace?(full_parts) do
          check_modules(body, full_parts)
        else
          {:error, {:forbidden_module, Enum.join(full_parts, ".")}}
        end

      {:defmodule, _meta, [mod_atom, [do: _body]]} when is_atom(mod_atom) ->
        {:error, {:forbidden_module, inspect(mod_atom)}}

      {:__block__, _meta, exprs} when is_list(exprs) ->
        Enum.reduce_while(exprs, :ok, fn expr, :ok ->
          case check_modules(expr, prefix) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)

      _ ->
        :ok
    end
  end

  defp resolve_parts([], parts), do: parts
  defp resolve_parts(_prefix, [:"Elixir" | rest]), do: rest
  defp resolve_parts(prefix, parts), do: prefix ++ parts

  defp allowed_namespace?([:Smap, :UserApp, _ | _]), do: true
  defp allowed_namespace?(_), do: false

  defp check_calls(ast) do
    {_ast, result} =
      Macro.prewalk(ast, :ok, fn
        node, {:error, _} = err ->
          {node, err}

        {{:., _, [target, fun]}, _, _args} = node, :ok when is_atom(fun) ->
          mod = resolve_target_module(target)

          if MapSet.member?(@forbidden_calls, {mod, fun}) do
            {node, {:error, {:forbidden_call, {mod, fun}}}}
          else
            {node, :ok}
          end

        node, :ok ->
          {node, :ok}
      end)

    result
  end

  defp resolve_target_module({:__aliases__, _, parts}), do: Module.concat(parts)
  defp resolve_target_module(atom) when is_atom(atom), do: atom
  defp resolve_target_module(_), do: nil
end
