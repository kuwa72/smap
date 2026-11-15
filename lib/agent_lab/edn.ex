defmodule AgentLab.EDN do
  @moduledoc """
  Minimal EDN reader for agent definition files (FR-1).

  Supports maps, vectors, lists, strings, keywords, numbers, booleans and nil.
  Commas are treated as whitespace per the EDN spec. Anything else
  (symbols, sets, tagged literals) is rejected.
  """

  @delims [?\s, ?\t, ?\n, ?\r, ?,, ?{, ?}, ?[, ?], ?(, ?), ?\", ?:]

  @spec decode(String.t()) :: {:ok, term()} | {:error, String.t()}
  def decode(text) when is_binary(text) do
    with {:ok, tokens} <- tokenize(text),
         {:ok, value, []} <- parse_value(tokens) do
      {:ok, value}
    else
      {:ok, _value, rest} -> {:error, "unexpected trailing input: #{inspect(rest)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- tokenizer ---

  defp tokenize(text), do: tokenize(text, [])

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<?;, rest::binary>>, acc), do: tokenize(skip_comment(rest), acc)

  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r, ?,],
    do: tokenize(rest, acc)

  defp tokenize(<<?{, rest::binary>>, acc), do: tokenize(rest, [:lbrace | acc])
  defp tokenize(<<?}, rest::binary>>, acc), do: tokenize(rest, [:rbrace | acc])
  defp tokenize(<<?[, rest::binary>>, acc), do: tokenize(rest, [:lbracket | acc])
  defp tokenize(<<?], rest::binary>>, acc), do: tokenize(rest, [:rbracket | acc])
  defp tokenize(<<?(, rest::binary>>, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(<<?), rest::binary>>, acc), do: tokenize(rest, [:rparen | acc])

  defp tokenize(<<?", rest::binary>>, acc) do
    case scan_string(rest, []) do
      {:ok, string, rest} -> tokenize(rest, [{:str, string} | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp tokenize(<<?:, rest::binary>>, acc) do
    {name, rest} = take_while(rest, &(&1 not in @delims), [])

    if name == "" do
      {:error, "empty keyword"}
    else
      tokenize(rest, [{:kw, String.to_atom(name)} | acc])
    end
  end

  defp tokenize(<<c, _::binary>> = text, acc) when (c >= ?0 and c <= ?9) or c == ?-,
    do: scan_number(text, acc)

  defp tokenize(<<c, _::binary>> = text, acc) when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z),
    do: scan_word(text, acc)

  defp tokenize(<<c, _::binary>>, _acc), do: {:error, "unexpected character #{inspect(<<c>>)}"}

  defp skip_comment(<<?\n, rest::binary>>), do: rest
  defp skip_comment(<<_, rest::binary>>), do: skip_comment(rest)
  defp skip_comment(<<>>), do: <<>>

  defp scan_string(<<>>, _acc), do: {:error, "unterminated string"}
  defp scan_string(<<?\n, _::binary>>, _acc), do: {:error, "unterminated string"}

  defp scan_string(<<?", rest::binary>>, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp scan_string(<<?\\, c, rest::binary>>, acc) do
    case unescape(c) do
      {:ok, char} -> scan_string(rest, [<<char::utf8>> | acc])
      {:error, _} -> {:error, "invalid escape \\#{<<c>>}"}
    end
  end

  defp scan_string(<<?\\, _::binary>>, _acc), do: {:error, "invalid escape"}

  defp scan_string(<<c::utf8, rest::binary>>, acc),
    do: scan_string(rest, [<<c::utf8>> | acc])

  defp unescape(?n), do: {:ok, ?\n}
  defp unescape(?t), do: {:ok, ?\t}
  defp unescape(?r), do: {:ok, ?\r}
  defp unescape(?b), do: {:ok, ?\b}
  defp unescape(?f), do: {:ok, ?\f}
  defp unescape(?\\), do: {:ok, ?\\}
  defp unescape(?\"), do: {:ok, ?\"}
  defp unescape(?/), do: {:ok, ?/}
  defp unescape(_), do: {:error, :bad_escape}

  defp take_while(<<>>, _pred, acc), do: {List.to_string(Enum.reverse(acc)), <<>>}

  defp take_while(<<c::utf8, rest::binary>>, pred, acc) do
    if pred.(c) do
      take_while(rest, pred, [c | acc])
    else
      {List.to_string(Enum.reverse(acc)), <<c::utf8, rest::binary>>}
    end
  end

  defp scan_word(text, acc) do
    {word, rest} = take_while(text, &(&1 not in @delims), [])

    case word do
      "true" -> tokenize(rest, [true | acc])
      "false" -> tokenize(rest, [false | acc])
      "nil" -> tokenize(rest, [nil | acc])
      _ -> {:error, "unsupported token #{inspect(word)}"}
    end
  end

  defp scan_number(text, acc) do
    {num, rest} = take_while(text, &(&1 in ?0..?9 or &1 in ~c"-+.eE"), [])

    value =
      cond do
        String.contains?(num, ".") or String.contains?(num, "e") or String.contains?(num, "E") ->
          case Float.parse(num) do
            {v, ""} -> v
            _ -> :error
          end

        true ->
          case Integer.parse(num) do
            {v, ""} -> v
            _ -> :error
          end
      end

    if value == :error do
      {:error, "invalid number #{inspect(num)}"}
    else
      tokenize(rest, [value | acc])
    end
  end

  # --- parser ---

  defp parse_value([]), do: {:error, "unexpected end of input"}
  defp parse_value([:lbrace | rest]), do: parse_map(rest, %{})
  defp parse_value([:lbracket | rest]), do: parse_seq(rest, :rbracket, [])
  defp parse_value([:lparen | rest]), do: parse_seq(rest, :rparen, [])

  defp parse_value([{kind, value} | rest]), do: {:ok, scalar(kind, value), rest}

  defp parse_value([value | rest]) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value, rest}

  defp parse_value([token | _]), do: {:error, "unexpected token #{inspect(token)}"}

  defp scalar(:str, v), do: v
  defp scalar(:kw, v), do: v
  defp scalar(v, _), do: v

  defp parse_map([], _acc), do: {:error, "unterminated map"}
  defp parse_map([:rbrace | rest], acc), do: {:ok, acc, rest}

  defp parse_map(tokens, acc) do
    with {:ok, key, rest} <- parse_value(tokens),
         {:ok, value, rest} <- parse_value(rest) do
      parse_map(rest, Map.put(acc, key, value))
    end
  end

  defp parse_seq([], _close, _acc), do: {:error, "unterminated list"}

  defp parse_seq([close | rest], close, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_seq(tokens, close, acc) do
    case parse_value(tokens) do
      {:ok, value, rest} -> parse_seq(rest, close, [value | acc])
      {:error, reason} -> {:error, reason}
    end
  end
end
