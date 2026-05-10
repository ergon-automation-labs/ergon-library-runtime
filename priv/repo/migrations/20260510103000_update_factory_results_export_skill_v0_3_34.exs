defmodule BotArmySkills.Repo.Migrations.UpdateFactoryResultsExportSkillV0_3_34 do
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
      WHERE tenant_id = $1::uuid
        AND slug = $2
      """,
      [@default_tenant_id, @skill_slug]
    )

    repo().query!(
      """
      WITH next_version AS (
        SELECT COALESCE(MAX(version), 0) + 1 AS value
        FROM skills
        WHERE tenant_id = $1::uuid
          AND slug = $2
      )
      INSERT INTO skills (tenant_id, name, slug, markdown_content, version, is_active, inserted_at, updated_at)
      SELECT
        $1::uuid,
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

    **Input Received:**
    proposal_id: {{ payload.proposal_id }}

    **Your Available Actions:**

    {{ action:query_factory_results }}
    {{ action:write_para_results }}
    {{ action:notify_factory_review }}

    ---

    **Workflow:**

    You must execute the following steps in order:

    **STEP 1: Query factory results**
    - Action name: `query_factory_results`
    - Input: proposal_id from payload
    - Expected output: status, passed_count, failed_count, timestamp

    **STEP 2: Format as markdown**
    - Create markdown content with execution status and test results
    - Include: proposal_id, status, passed/failed counts, total, timestamp

    **STEP 3: Export to para inbox**
    - Action name: `write_para_results`
    - Parameters:
      - relative_path: `inbox/factory-results-{{ payload.proposal_id }}.md`
      - content: the markdown from step 2
      - mode: `write`

    **STEP 4: Notify user**
    - Action name: `notify_factory_review`
    - Body: JSON intent with proposal_id, results summary, para file path
    - Domain: factory
    - Intent type: review_request

    **Success Output:**
    "✓ Factory results exported to: inbox/factory-results-{{ payload.proposal_id }}.md"

    **Failure Output:**
    Report the step that failed and why.
    """
  end
end
