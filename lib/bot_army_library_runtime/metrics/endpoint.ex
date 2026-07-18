defmodule BotArmyLibraryRuntime.Metrics.Endpoint do
  @moduledoc """
  HTTP endpoint serving Prometheus metrics at /metrics on port 9090.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    metrics = PromEx.get_metrics(BotArmyLibraryRuntime.PromEx)

    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, metrics)
  end

  match _ do
    conn
    |> Plug.Conn.send_resp(404, "Not Found")
  end
end
