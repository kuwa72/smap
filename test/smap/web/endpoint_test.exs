defmodule Smap.Web.EndpointTest do
  use ExUnit.Case, async: false

  alias Smap.Web.Endpoint

  test "runs resident HTTP server bound to 127.0.0.1 and serves GET /" do
    port = Endpoint.port()
    assert is_integer(port) and port > 0
    assert Endpoint.url() == "http://127.0.0.1:#{port}"

    resp = Req.get!(Endpoint.url() <> "/")
    assert resp.status == 200
    assert resp.body =~ "chat-panel"
    assert resp.body =~ "app-slot"
  end
end
