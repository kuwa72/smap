defmodule Smap.AppSpace.Safety do
  @moduledoc """
  AST-level safety checks run before compiling user-generated application code.

  Guards against BEAM-specific risks:
  1. Overwriting core modules: every `defmodule` (at any nesting depth, even
     inside `if`/`case`/`for`) must resolve under `Smap.UserApp.*`.
  2. VM-halting / destructive calls: `System.halt`, `:init.stop`,
     `:erlang.halt`, `:os.cmd`, `Code.compile_string`, direct `:code`
     manipulation, `import` of forbidden modules, and dynamic `apply/2,3`.
  """

  @forbidden_calls MapSet.new([
                     {System, :halt},
                     {System, :stop},
                     {System, :cmd},
                     {:init, :stop},
                     {:init, :restart},
                     {:erlang, :halt},
                     {:erlang, :apply},
                     {Kernel, :apply},
                     {:os, :cmd},
                     {Code, :compile_string},
                     {Code, :eval_string},
                     {Code, :eval_quoted},
                     {:code, :load_binary},
                     {:code, :delete},
                     {:code, :purge},
                     {:code, :soft_purge}
                   ])

  @forbidden_imports MapSet.new([System, :init, :erlang, :os, :code, Code])
  @forbidden_local_calls MapSet.new([:apply, :halt])

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

  @doc "Verify compiled module atoms all live under `Smap.UserApp.*`."
  @spec validate_compiled_modules([{module(), binary()}]) :: :ok | {:error, term()}
  def validate_compiled_modules(compiled) when is_list(compiled) do
    Enum.reduce_while(compiled, :ok, fn {mod, _bin}, :ok ->
      case Module.split(mod) do
        ["Smap", "UserApp", _ | _] -> {:cont, :ok}
        _ -> {:halt, {:error, {:forbidden_module, inspect(mod)}}}
      end
    end)
  end

  # Recursively walk every AST node so `defmodule` hidden inside `if`/`case`/`for`
  # or any other expression is always inspected with its enclosing module prefix.
  defp check_modules({:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, prefix) do
    full_parts = resolve_parts(prefix, parts)

    if allowed_namespace?(full_parts) do
      check_modules(body, full_parts)
    else
      {:error, {:forbidden_module, Enum.join(full_parts, ".")}}
    end
  end

  defp check_modules({:defmodule, _meta, [mod_expr, _]}, _prefix) do
    {:error, {:forbidden_module, Macro.to_string(mod_expr)}}
  end

  defp check_modules({_form, _meta, args}, prefix) when is_list(args) do
    check_modules_list(args, prefix)
  end

  defp check_modules({left, right}, prefix) do
    with :ok <- check_modules(left, prefix), do: check_modules(right, prefix)
  end

  defp check_modules(list, prefix) when is_list(list) do
    check_modules_list(list, prefix)
  end

  defp check_modules(_literal, _prefix), do: :ok

  defp check_modules_list(list, prefix) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case check_modules(item, prefix) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
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

        {:import, _, [target | _]} = node, :ok ->
          mod = resolve_target_module(target)

          if MapSet.member?(@forbidden_imports, mod) do
            {node, {:error, {:forbidden_call, {:import, mod}}}}
          else
            {node, :ok}
          end

        {{:., _, [target, fun]}, _, _args} = node, :ok when is_atom(fun) ->
          mod = resolve_target_module(target)

          if MapSet.member?(@forbidden_calls, {mod, fun}) do
            {node, {:error, {:forbidden_call, {mod, fun}}}}
          else
            {node, :ok}
          end

        {fun, _, args} = node, :ok when is_atom(fun) and is_list(args) ->
          if MapSet.member?(@forbidden_local_calls, fun) do
            {node, {:error, {:forbidden_call, {Kernel, fun}}}}
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
