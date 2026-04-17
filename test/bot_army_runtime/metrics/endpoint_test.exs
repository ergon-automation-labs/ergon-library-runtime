defmodule BotArmyRuntime.Metrics.EndpointTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias BotArmyRuntime.Metrics.Endpoint

  describe "GET /metrics" do
    test "returns 200 with prometheus text format" do
      conn =
        conn(:get, "/metrics")
        |> Endpoint.call([])

      assert conn.status == 200
    end

    test "returns text/plain content type" do
      conn =
        conn(:get, "/metrics")
        |> Endpoint.call([])

      content_type = Plug.Conn.get_resp_header(conn, "content-type") |> List.first()
      assert content_type =~ "text/plain"
    end

    test "returns prometheus-formatted metrics body" do
      conn =
        conn(:get, "/metrics")
        |> Endpoint.call([])

      assert is_binary(conn.resp_body)
    end
  end

  describe "GET /unknown" do
    test "returns 404" do
      conn =
        conn(:get, "/unknown")
        |> Endpoint.call([])

      assert conn.status == 404
    end
  end

  describe "POST /metrics" do
    test "returns 404 for non-GET methods" do
      conn =
        conn(:post, "/metrics")
        |> Endpoint.call([])

      assert conn.status == 404
    end
  end
end
