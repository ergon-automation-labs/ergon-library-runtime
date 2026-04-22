# `BotArmyRuntime.Tenant`

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
    BotArmyRuntime.Tenant.default_tenant_id()

    # Build a tenant-aware subject
    subject = BotArmyRuntime.Tenant.subject("gtd.task.list", "default")

    # Extract tenant from a subject
    tenant_id = BotArmyRuntime.Tenant.from_subject("tenant.abc123.gtd.tasks")

# `default_tenant_id`

Returns the default tenant UUID for single-tenant deployments.

Abby's personal deployment uses `"00000000-0000-0000-0000-000000000001"` as the tenant ID.
SaaS tenants will have unique UUIDs assigned at provisioning.

# `from_subject`

Extracts tenant ID from a tenant-prefixed subject.

Returns `nil` if the subject doesn't match the tenant prefix pattern.

## Examples

    iex> BotArmyRuntime.Tenant.from_subject("tenant.default.gtd.tasks")
    "default"

    iex> BotArmyRuntime.Tenant.from_subject("gtd.tasks")
    nil

# `strip_tenant_prefix`

Strips the tenant prefix from a subject, returning the core subject.

Returns `nil` if the subject is not tenant-prefixed.

## Examples

    iex> BotArmyRuntime.Tenant.strip_tenant_prefix("tenant.00000000-0000-0000-0000-000000000001.gtd.tasks")
    "gtd.tasks"

    iex> BotArmyRuntime.Tenant.strip_tenant_prefix("gtd.tasks")
    nil

# `subject`

Builds a tenant-prefixed NATS subject.

## Examples

    iex> BotArmyRuntime.Tenant.subject("gtd.task.list", "00000000-0000-0000-0000-000000000001")
    "tenant.00000000-0000-0000-0000-000000000001.gtd.task.list"

    iex> BotArmyRuntime.Tenant.subject("dungeon.session.start", "acme-corp")
    "tenant.acme-corp.dungeon.session.start"

# `tenant_subject?`

Checks if a subject is tenant-prefixed.

## Examples

    iex> BotArmyRuntime.Tenant.tenant_subject?("tenant.00000000-0000-0000-0000-000000000001.gtd.tasks")
    true

    iex> BotArmyRuntime.Tenant.tenant_subject?("gtd.tasks")
    false

---

*Consult [api-reference.md](api-reference.md) for complete listing*
