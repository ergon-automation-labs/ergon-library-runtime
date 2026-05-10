defmodule BotArmySkills.Repo.Migrations.AddFactoryResultsExportSkillAndActions do
  use Ecto.Migration

  @default_tenant_id "00000000-0000-0000-0000-000000000001"
  @skill_slug "factory_results_export"
  @skill_name "factory-results-export"
  @query_action_slug "query_factory_results"
  @write_action_slug "write_para_results"
  @notify_action_slug "notify_factory_review"
  @action_type "nats_request"
  @publish_action_type "nats_publish"

  def up do
    upsert_query_factory_results_action()
    upsert_write_para_results_action()
    upsert_notify_factory_review_action()
    upsert_factory_results_export_skill()
  end

  def down do
    repo().query!(
      """
      DELETE FROM tenant_actions
      WHERE tenant_id = $1
        AND slug IN ($2, $3, $4)
      """,
      [@default_tenant_id, @query_action_slug, @write_action_slug, @notify_action_slug]
    )

    repo().query!(
      """
      DELETE FROM skills
      WHERE tenant_id = $1
        AND slug = $2
      """,
      [@default_tenant_id, @skill_slug]
    )
  end

  defp upsert_query_factory_results_action do
    config =
      Jason.encode!(%{
        "subject" => "factory.execution.results",
        "envelope" => true,
        "timeout_ms" => 10_000
      })

    repo().query!(
      """
      INSERT INTO tenant_actions (tenant_id, slug, type, config_json, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4::jsonb, true, timezone('UTC', now()), timezone('UTC', now()))
      ON CONFLICT (tenant_id, slug)
      DO UPDATE SET
        type = EXCLUDED.type,
        config_json = EXCLUDED.config_json,
        is_active = true,
        updated_at = timezone('UTC', now())
      """,
      [@default_tenant_id, @query_action_slug, @action_type, config]
    )
  end

  defp upsert_write_para_results_action do
    config =
      Jason.encode!(%{
        "subject" => "para.fs.write",
        "envelope" => false,
        "timeout_ms" => 10_000
      })

    repo().query!(
      """
      INSERT INTO tenant_actions (tenant_id, slug, type, config_json, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4::jsonb, true, timezone('UTC', now()), timezone('UTC', now()))
      ON CONFLICT (tenant_id, slug)
      DO UPDATE SET
        type = EXCLUDED.type,
        config_json = EXCLUDED.config_json,
        is_active = true,
        updated_at = timezone('UTC', now())
      """,
      [@default_tenant_id, @write_action_slug, @action_type, config]
    )
  end

  defp upsert_notify_factory_review_action do
    config =
      Jason.encode!(%{
        "subject" => "synapse.intent.notification.request",
        "envelope" => true,
        "timeout_ms" => 5_000
      })

    repo().query!(
      """
      INSERT INTO tenant_actions (tenant_id, slug, type, config_json, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4::jsonb, true, timezone('UTC', now()), timezone('UTC', now()))
      ON CONFLICT (tenant_id, slug)
      DO UPDATE SET
        type = EXCLUDED.type,
        config_json = EXCLUDED.config_json,
        is_active = true,
        updated_at = timezone('UTC', now())
      """,
      [@default_tenant_id, @notify_action_slug, @publish_action_type, config]
    )
  end

  defp upsert_factory_results_export_skill do
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
    llm_hint: fast
    ---
    You are a factory results export assistant.

    **Task:** Export factory execution results to para inbox and notify user for review.

    **Input:**
    - proposal_id: {{ payload.proposal_id }}

    **Available Actions:**

    {{ action:query_factory_results }}
    {{ action:write_para_results }}
    {{ action:notify_factory_review }}

    **Execution Steps:**

    1. Call `query_factory_results` action with proposal_id to get:
       - status, passed_count, failed_count, timestamp, any error details

    2. Format results as markdown file content:
       ```markdown
       # Factory Results: {proposal_id}
       **Status:** {status}
       **Passed:** {passed_count}
       **Failed:** {failed_count}
       **Total:** {passed_count + failed_count}
       **Executed:** {timestamp}
       ```

    3. Call `write_para_results` action with:
       - relative_path: `inbox/factory-results-{{ payload.proposal_id }}.md`
       - content: markdown from step 2
       - mode: "write"

    4. Call `notify_factory_review` action with payload:
       ```json
       {
         "intent_type": "review_request",
         "domain": "factory",
         "priority": "high",
         "data": {
           "proposal_id": "{{ payload.proposal_id }}",
           "status": "{status from action 1}",
           "summary": "{passed}/{total} passed",
           "para_path": "inbox/factory-results-{{ payload.proposal_id }}.md",
           "suggested_actions": ["view_in_para", "approve_results"]
         }
       }
       ```

    **Response:**
    Report success with the para file path, or report what failed and why.
    """
  end
end
