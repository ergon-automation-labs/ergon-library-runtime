defmodule BotArmySkills.Repo.Migrations.UpdateFactoryResultsExportSkillWithActions do
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
    You are a factory results export assistant.

    **Task:** Export factory execution results to para inbox and notify user for review.

    **Input:**
    proposal_id: {{ payload.proposal_id }}

    **Available Actions:**

    {{ action:query_factory_results }}
    {{ action:write_para_results }}
    {{ action:notify_factory_review }}

    ---

    **Workflow:**

    You must execute the following steps in order:

    **STEP 1: Query factory results**
    - Invoke the `query_factory_results` action with proposal_id from payload
    - You will receive: status, passed_count, failed_count, timestamp
    - If this fails, report the error and stop

    **STEP 2: Format results as markdown**
    Create markdown content with the following structure:
    ```
    # Factory Results: {{ payload.proposal_id }}

    **Status:** [status from step 1]
    **Passed:** [passed_count from step 1]
    **Failed:** [failed_count from step 1]
    **Total:** [passed_count + failed_count]
    **Executed:** [timestamp from step 1]
    ```

    **STEP 3: Export to para inbox**
    - Invoke the `write_para_results` action
    - Pass the markdown content from step 2
    - The file will be written to: inbox/factory-results-{{ payload.proposal_id }}.md
    - If this fails, report the error and stop

    **STEP 4: Notify user via Synapse**
    - Invoke the `notify_factory_review` action
    - Include: proposal_id, status from step 1, passed/total summary, para file path
    - This sends a review notification to the user

    **Success Output:**
    Report: "✓ Factory results exported to inbox/factory-results-{{ payload.proposal_id }}.md and user notified"

    **Failure Output:**
    Report which step failed and the error details.
    """
  end
end
