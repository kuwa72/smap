defmodule AgentLab.Envelope do
  @moduledoc "Structured agent message (FR-4 transport payload)."

  @enforce_keys [:from, :type, :payload]
  defstruct [:from, :to, :topic, :type, :payload, :id, :in_reply_to, :ts]

  @type t :: %__MODULE__{
          from: term(),
          to: term(),
          topic: term(),
          type: term(),
          payload: term(),
          id: term(),
          in_reply_to: term(),
          ts: String.t()
        }

  @doc "`to` is a pid, a registered name/role, or nil when `topic` is set."
  @spec new(term(), term(), term(), keyword()) :: t()
  def new(from, type, payload, opts \\ []) do
    %__MODULE__{
      from: from,
      to: Keyword.get(opts, :to),
      topic: Keyword.get(opts, :topic),
      type: type,
      payload: payload,
      id: Keyword.get(opts, :id, System.unique_integer([:positive])),
      in_reply_to: Keyword.get(opts, :in_reply_to),
      ts: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
