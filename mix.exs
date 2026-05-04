defmodule BotArmyRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :bot_army_runtime,
      version: "0.13.1",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      # Start Jason before Sentry — Sentry.Application validates the json library at boot
      extra_applications: [:logger, :inets, :jason],
      mod: {BotArmyRuntime.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      {:gnat, "~> 1.6"},
      {:elixir_uuid, "~> 1.2"},
      {:telemetry, "~> 1.2"},
      {:logger_json, "~> 5.1"},
      {:prom_ex, "~> 1.11"},
      {:plug_cowboy, "~> 2.7"},
      {:sentry, "~> 10.0", runtime: false},
      {:hackney, "~> 1.20"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:ex_doc, "~> 0.30", only: :dev},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mock, "~> 0.3.0", only: :test}
    ]
  end
end
