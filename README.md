# terraform-lakeflow-postgres-prereqs

A Terraform module that prepares an AWS RDS / Aurora **PostgreSQL** database as a
change-data-capture (CDC) source for **Databricks Lakeflow Connect**.

It turns the manual source-side runbook into reviewable code: logical replication,
a least-privilege replication user, a publication, a replication slot, a WAL
retention cap, `REPLICA IDENTITY FULL` for tables without a primary key, and a
post-apply verification script.

> **Status: untested against a live database.** The module passes `terraform validate`
> and an 11-case `terraform test` suite that runs against mocked providers. It has not
> yet been applied to a real RDS/Aurora instance. See [Known gaps](#known-gaps).

## What it does

| Runbook step | Handled by |
|---|---|
| Enable logical replication (`rds.logical_replication = 1`) | Parameter group (cluster-level for Aurora) |
| Dedicated replication user, least privilege | `postgresql_role`, `postgresql_grant_role` (`rds_replication`), `postgresql_grant`, `postgresql_default_privileges` |
| Publication with an explicit table list | `postgresql_publication` |
| Replication slot (`pgoutput`) | `postgresql_replication_slot` (`prevent_destroy`) |
| WAL retention cap | `max_slot_wal_keep_size` in the parameter group, derived from storage or set explicitly |
| `REPLICA IDENTITY FULL` for PK-less tables | Idempotent `ALTER TABLE` via `psql` (no native Terraform resource exists) |
| Verification | `scripts/verify.sh` and the `expected_state` output |
| Credentials hand-off | Generated with `random_password`, written to AWS Secrets Manager as JSON |

## Layout

```
modules/postgres_cdc_source/   the reusable module (+ tests/)
examples/basic/                a thin root: one run = one source = one state file
scripts/verify.sh              read-only post-apply verification
scripts/reboot.sh              the deliberate reboot step (dry run by default)
```

## Two-phase apply (the important part)

A logical replication slot cannot be created until logical replication is active, and
`rds.logical_replication` is a **static** parameter that needs a reboot. So the module
is applied in two phases, and **Terraform never reboots anything**.

1. **Phase 1** - `enable_postgres_objects = false` (default). Creates the parameter
   group and the secret container.
2. **Attach and reboot.** Attach `parameter_group_name` to the instance/cluster (in the
   stack that owns it), then run `scripts/reboot.sh --identifier <db>` (dry run) and
   `--confirm` when ready. This causes a brief outage - schedule it.
3. **Phase 2** - `enable_postgres_objects = true`. Creates the role, grants, publication,
   slot and REPLICA IDENTITY settings, then writes the credentials to the secret.
4. **Verify** - run `scripts/verify.sh`.

```hcl
module "cdc_source" {
  source = "github.com/shivasai-ad/terraform-lakeflow-postgres-prereqs//modules/postgres_cdc_source?ref=<tag-or-commit>"

  name        = "orders"
  environment = "dev"

  enable_postgres_objects = false # flip to true after the reboot

  allocated_storage_gb   = 110
  parameter_group_family = "postgres17"

  host           = "orders-db.example.eu-central-1.rds.amazonaws.com"
  database       = "orders"
  admin_username = "postgres"
  admin_password = var.admin_password

  publication_tables           = ["public.customer", "public.order", "public.order_line"]
  replica_identity_full_tables = ["public.order_line"] # no primary key
}
```

The `postgresql` provider is configured in the **calling root**, not the module. Provider
blocks cannot be driven by `for_each`, so run one root (and one state) per source - see
`examples/basic`.

## Key inputs

| Variable | Purpose |
|---|---|
| `enable_postgres_objects` | Phase gate (default `false`) |
| `publication_tables` | Explicit schema-qualified table list (validated as plain identifiers) |
| `replica_identity_full_tables` | PK-less tables; must be a subset of `publication_tables` |
| `allocated_storage_gb` / `wal_retention_percent` | Derives the WAL cap (default 15% of storage) |
| `max_slot_wal_keep_size_mb` | Explicit cap in MB; overrides the derived one. Required for Aurora |
| `is_aurora` / `parameter_group_family` | Cluster vs instance parameter group |
| `manage_parameter_group` | Set `false` if another stack owns the group |
| `manage_secret` / `secret_name` | Set `manage_secret = false` if another stack owns the secret |
| `use_rds_replication_role` | `true` for RDS/Aurora (`rds_replication`), `false` for self-managed |

## WAL cap: the tradeoff

`max_slot_wal_keep_size` bounds how much WAL a replication slot may hold back. If the
consumer (the Lakeflow gateway) is offline long enough to exceed it, Postgres
**invalidates the slot** and the pipeline needs a **full re-snapshot** of the affected
tables. A larger cap means more disk risk; a smaller cap means more re-snapshot risk.
Size it to your storage and how long an outage you want to survive, and alert on slot lag.
The 15% default is a starting point, not a recommendation.

## Ownership rules

- The module only **creates** the parameter group; it cannot attach it to an instance
  owned elsewhere. Pass `parameter_group_name` to whatever stack owns the instance.
- If another stack already owns the credentials secret, set `manage_secret = false`
  and write the `replication_password` output there. Two stacks must not own one secret.
- `prevent_destroy` on the slot is intentional: recreating it loses the WAL position.
  `terraform destroy` will refuse until you remove it deliberately.

## Connectivity and security

- `terraform apply` needs direct network access to the database (a runner inside the VPC,
  or a bastion/tunnel). The `psql` step also needs `psql` installed there.
- The generated password and the admin password live in Terraform state. Use an
  encrypted remote backend and restrict who can read it.
- Table and schema names are validated against a strict identifier regex before being
  placed into SQL.

## Verification

`scripts/verify.sh` is read-only and checks: `wal_level = logical`, the replication user
and its privilege, `SELECT` on every published table, the publication and its members,
the slot (`pgoutput`), `REPLICA IDENTITY FULL` on declared tables, the cap value, and -
the check that catches the classic failure - **any published table with no primary key
and no `REPLICA IDENTITY FULL`**. Feed it the module's `expected_state` output.

```bash
export PGHOST=... PGDATABASE=... PGUSER=... PGPASSWORD=...
REPL_USER=lakeflow_replication PUBLICATION=lakeflow_publication SLOT=lakeflow_slot \
TABLES=public.customer,public.order PKLESS_TABLES=public.order_line \
scripts/verify.sh
```

## Known gaps

- **Not applied to a live database yet.** Provider behaviour (publication/slot on RDS,
  `rds_replication` grants, default privileges) is unconfirmed until a real dev apply.
- **`max_slot_wal_keep_size` on Aurora** may not behave as on RDS PostgreSQL, and the
  parameter unit (MB) should be confirmed for your engine version.
- **`scripts/reboot.sh` Aurora path** (per-instance reboot with a cluster parameter group)
  has not been exercised.
- **`REPLICA IDENTITY` drift** (changed out-of-band) is not detected by `terraform plan`;
  `verify.sh` detects it.
- No license file is included yet; add one before others reuse this.

## Development

```bash
cd modules/postgres_cdc_source
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test          # mocked providers - no AWS or database needed
```
