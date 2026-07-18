defmodule BotArmyLibraryRuntime.Tenant do
  @moduledoc """
  Tenant management utilities for multi-tenancy support.

  This module provides utilities for working with tenants in the Bot Army
  ecosystem, including the default tenant ID and tenant-aware subject routing.

  ## Default Tenant

  Abby's personal deployment uses `tenant_id = "default"`. This is the
  single-tenant case that existing bots handle.

  ## Subject Prefixing

  Tenant-specific NATS subjects follow the pattern:
      tenant.<tenant_id>.events.*
      tenant.<tenant_id>.gtd.*
      etc.

  ## Usage

      # Get the default tenant ID
      BotArmyLibraryRuntime.Tenant.default_tenant_id()

      # Build a tenant-aware subject
      subject = BotArmyLibraryRuntime.Tenant.subject("gtd.task.list", "default")

      # Extract tenant from a subject
      tenant_id = BotArmyLibraryRuntime.Tenant.from_subject("tenant.abc123.gtd.tasks")
  """

  @default_tenant_id "00000000-0000-0000-0000-000000000001"

  @doc """
  Returns the default tenant UUID for single-tenant deployments.

  Abby's personal deployment uses `"00000000-0000-0000-0000-000000000001"` as the tenant ID.
  SaaS tenants will have unique UUIDs assigned at provisioning.
  """
  def default_tenant_id, do: @default_tenant_id

  @doc """
  Builds a tenant-prefixed NATS subject.

  ## Examples

      iex> BotArmyLibraryRuntime.Tenant.subject("gtd.task.list", "00000000-0000-0000-0000-000000000001")
      "tenant.00000000-0000-0000-0000-000000000001.gtd.task.list"

      iex> BotArmyLibraryRuntime.Tenant.subject("dungeon.session.start", "acme-corp")
      "tenant.acme-corp.dungeon.session.start"
  """
  def subject(subject, tenant_id) when is_binary(subject) and is_binary(tenant_id) do
    "tenant.#{tenant_id}.#{subject}"
  end

  @doc """
  Extracts tenant ID from a tenant-prefixed subject.

  Returns `nil` if the subject doesn't match the tenant prefix pattern.

  ## Examples

      iex> BotArmyLibraryRuntime.Tenant.from_subject("tenant.default.gtd.tasks")
      "default"

      iex> BotArmyLibraryRuntime.Tenant.from_subject("gtd.tasks")
      nil
  """
  def from_subject(subject) when is_binary(subject) do
    case Regex.run(~r/^tenant\.([^.]+)\./, subject) do
      [_full, tenant_id] -> tenant_id
      _ -> nil
    end
  end

  @doc """
  Checks if a subject is tenant-prefixed.

  ## Examples

      iex> BotArmyLibraryRuntime.Tenant.tenant_subject?("tenant.00000000-0000-0000-0000-000000000001.gtd.tasks")
      true

      iex> BotArmyLibraryRuntime.Tenant.tenant_subject?("gtd.tasks")
      false
  """
  def tenant_subject?(subject) when is_binary(subject) do
    String.starts_with?(subject, "tenant.")
  end

  @doc """
  Strips the tenant prefix from a subject, returning the core subject.

  Returns `nil` if the subject is not tenant-prefixed.

  ## Examples

      iex> BotArmyLibraryRuntime.Tenant.strip_tenant_prefix("tenant.00000000-0000-0000-0000-000000000001.gtd.tasks")
      "gtd.tasks"

      iex> BotArmyLibraryRuntime.Tenant.strip_tenant_prefix("gtd.tasks")
      nil
  """
  def strip_tenant_prefix(subject) when is_binary(subject) do
    if tenant_subject?(subject) do
      # Remove "tenant.<tenant_id>." prefix
      subject
      |> String.replace_prefix("tenant.", "")
      |> String.replace_prefix(from_subject(subject) <> ".", "")
    else
      nil
    end
  end
end
