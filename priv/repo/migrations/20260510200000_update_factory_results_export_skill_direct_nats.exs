defmodule BotArmySkills.Repo.Migrations.UpdateFactoryResultsExportSkillDirectNats do
  use Ecto.Migration

  @default_tenant_id "00000000-0000-0000-0000-000000000001"
  @skill_slug "factory_results_export"
  @skill_name "factory-results-export"

  def up do
    update_factory_results_export_skill()
  end

  def down do
    # Downgrade is handled by version control; no need to revert
    :ok
  end

  defp update_factory_results_export_skill do
    markdown = canonical_skill_markdown()

    repo().query!(
      """
      UPDATE skills
      SET is_active = false, updated_at = timezone('UTC', now())
      WHERE tenant_id = $1
        AND slug = $2
      """,
      [@default_tenant_id, @skill_slug]
    )

    repo().query!(
      """
      WITH next_version AS (
        SELECT COALESCE(MAX(version), 0) + 1 AS value
        FROM skills
        WHERE tenant_id = $1
          AND slug = $2
      )
      INSERT INTO skills (tenant_id, name, slug, markdown_content, version, is_active, inserted_at, updated_at)
      SELECT
        $1,
        $3,
        $2,
        $4,
        next_version.value,
        true,
        timezone('UTC', now()),
        timezone('UTC', now())
      FROM next_version
      ON CONFLICT (tenant_id, slug, version) DO NOTHING
      """,
      [@default_tenant_id, @skill_slug, @skill_name, markdown]
    )
  end

  defp canonical_skill_markdown do
    """
    ---
    name: factory-results-export
    slug: factory_results_export
    description: Query factory execution results, export to para inbox, and notify user via Synapse for review.
    triggers: bot.army.skills.command.factory_results_export
    llm_hint: quality
    ---
    You are a factory results export assistant with direct NATS access.

    **Input:**
    proposal_id: {{ payload.proposal_id }}

    **Your Job:**

    1. **Query factory results** by making a NATS request to `factory.execution.results` with `{"proposal_id": "{{ payload.proposal_id }}"}`
       - Extract from response: status, passed_count, failed_count, timestamp
       - If query fails, report the error and stop

    2. **Format results as markdown:**
       ```
       # Factory Results: {{ payload.proposal_id }}

       **Status:** [from query]
       **Passed:** [from query]
       **Failed:** [from query]
       **Total:** [passed + failed]
       **Executed:** [from query timestamp]
       ```

    3. **Export to para inbox** by making a NATS request to `para.fs.write` with:
       ```json
       {
         "schema_version": "1.0",
         "relative_path": "inbox/factory-results-{{ payload.proposal_id }}.md",
         "content": "[markdown from step 2]",
         "mode": "write"
       }
       ```
       - If write fails, report the error and stop

    4. **Notify user** by publishing to `synapse.intent.notification.request`:
       ```json
       {
         "intent_type": "review_request",
         "domain": "factory",
         "priority": "high",
         "delivery_policy": {"channel_strategy": "last_successful_user_surface"},
         "data": {
           "proposal_id": "{{ payload.proposal_id }}",
           "status": "[from query]",
           "summary": "[passed]/[total] passed",
           "para_path": "inbox/factory-results-{{ payload.proposal_id }}.md",
           "suggested_actions": ["view_in_para", "approve_results"]
         }
       }
       ```

    **Success Output:**
    Report: "✓ Exported to inbox/factory-results-{{ payload.proposal_id }}.md and notified user"

    **Failure Output:**
    Report which step failed and the error details.
    """
  end
end
