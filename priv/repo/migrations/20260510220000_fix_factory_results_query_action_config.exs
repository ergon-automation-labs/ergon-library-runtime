defmodule BotArmySkills.Repo.Migrations.FixFactoryResultsQueryActionConfig do
  use Ecto.Migration

  @default_tenant_id "00000000-0000-0000-0000-000000000001"
  @query_action_slug "query_factory_results"

  def up do
    fix_query_factory_results_action()
  end

  def down do
    # Downgrade is handled by version control; no need to revert
    :ok
  end

  defp fix_query_factory_results_action do
    # Remove payload_key from config — the entire payload (which contains proposal_id) should be sent
    config =
      Jason.encode!(%{
        "subject" => "factory.execution.results",
        "envelope" => true,
        "timeout_ms" => 10_000
      })

    repo().query!(
      """
      UPDATE tenant_actions
      SET config_json = $1::jsonb, updated_at = timezone('UTC', now())
      WHERE tenant_id = $2
        AND slug = $3
      """,
      [config, @default_tenant_id, @query_action_slug]
    )
  end
end
