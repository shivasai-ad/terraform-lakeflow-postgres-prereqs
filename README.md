# terraform-lakeflow-postgres-prereqs

A Terraform module that prepares an AWS **RDS for PostgreSQL** database as a
change-data-capture (CDC) source for **Databricks Lakeflow Connect**.

It turns the manual source-side runbook into reviewable code: logical replication,
a least-privilege replication user, a publication, a replication slot, a WAL
retention cap, `REPLICA IDENTITY FULL` for tables without a primary key, a
post-apply verification script, and a preflight check.

> **Status.** Validated, covered by a 15-case `terraform test` suite (mocked providers), and
> exercised end to end - real `apply`, idempotent re-plan, drift detection, lock timeout - against a
> **local PostgreSQL 16 that imitates RDS**. **Not yet run against real RDS or real AWS** (parameter
> group, Secrets Manager, the actual reboot). See [Known gaps](#known-gaps) and
> [docs/decisions.md](docs/decisions.md).

## What it does

| Runbook step | Handled by |
|---|---|
| Enable logical replication (`rds.logical_replication = 1`) | RDS parameter group |
| Dedicated replication user, least privilege | `postgresql_role` (member of `rds_replication`), `postgresql_grant`, `postgresql_default_privileges` |
| Publication with an explicit table list | `postgresql_publication` |
| Replication slot (`pgoutput`) | `postgresql_replication_slot` (`prevent_destroy`) |
| WAL retention cap | `max_slot_wal_keep_size` in the parameter group, from storage or set explicitly |
| `REPLICA IDENTITY FULL` for PK-less tables | Idempotent `ALTER TABLE` via `psql` (no native Terraform resource exists) |
| Verification | `scripts/verify.sh` and the `expected_state` output |
| Credentials hand-off | `random_password`, stored in a new secret or merged into an existing one |

## Layout

```
main.tf  variables.tf  outputs.tf  versions.tf   the root configuration (providers + the module call)
envs/dev.tfvars                                  non-secret settings for one environment / source
modules/postgres_cdc_source/
  main.tf          Phase 1: the parameter group
  postgres.tf      Phase 2: role, grants, publication, slot, REPLICA IDENTITY
  credentials.tf   Phase 2: password and secret (new, or merged into an existing one)
  tests/           mocked-provider tests
scripts/preflight.sh   run BEFORE apply: connectivity, login, ownership, slots
scripts/reboot.sh      the approved reboot step (report-only by default)
scripts/verify.sh      read-only post-apply verification
docs/decisions.md      the design decisions and what is still open
.github/workflows/     CI: fmt, validate, tests, shellcheck (no apply - see Connectivity)
```

One run of the root = one source database = one state file. The `postgresql` provider is configured once
in `main.tf` (provider blocks cannot be driven by `for_each`), so another source or environment is another
`envs/*.tfvars` file and another state key - not another provider alias.

## Two-phase apply

A logical replication slot cannot be created until logical replication is active, and
`rds.logical_replication` is a **static** parameter that needs a reboot. So the module runs in two
phases, and **Terraform never reboots anything**.

1. **Preflight** - from the runner: `PHASE=1 TABLES=... scripts/preflight.sh`.
2. **Phase 1** - `enable_postgres_objects = false` (default). Creates only the parameter group.
3. **Attach and reboot.** Attach `parameter_group_name` to the instance (in the stack that owns it),
   then `scripts/reboot.sh ... --approved-by "name / ticket" --confirm`. It refuses unless the group
   is attached and a reboot is pending. This causes a brief outage - schedule it.
4. **Phase 2** - `enable_postgres_objects = true`. Creates the role, grants, publication, slot and
   REPLICA IDENTITY settings, then the password and secret.
5. **Verify** - `scripts/verify.sh`, after every apply.

## Running it

```bash
# 1. Initialise with this environment's own state (one state per environment / source)
terraform init \
  -backend-config="bucket=<state-bucket>" \
  -backend-config="key=dev/orders/cdc-prereqs.tfstate" \
  -backend-config="region=<region>"

# 2. The admin password comes from the environment, never from a file
export TF_VAR_admin_password='...'

# 3. Phase 1 (enable_postgres_objects = false in envs/dev.tfvars)
terraform plan  -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars

# ... attach the parameter group, reboot, confirm wal_level = logical ...

# 4. Phase 2: set enable_postgres_objects = true in envs/dev.tfvars, then plan and apply again
```

**Adding an environment or source:** copy `envs/dev.tfvars` to `envs/<name>.tfvars`, edit it, and
`init` with a different state key. Run `terraform plan` and `apply` from a self-hosted runner that can
reach the database (see Connectivity).

The module is self-contained under `modules/postgres_cdc_source`, so another repository can also call it
by git source instead of using this root.

## Key inputs

| Variable | Purpose |
|---|---|
| `enable_postgres_objects` | Phase gate (default `false`) |
| `publication_tables` | Explicit schema-qualified table list (validated as plain identifiers) |
| `replica_identity_full_tables` | PK-less tables; must be a subset of `publication_tables` |
| `table_owner` | Role that creates your tables (default SELECT for the replication user) |
| `allocated_storage_gb` / `wal_retention_percent` | Derives the WAL cap (default 15% of storage) |
| `max_slot_wal_keep_size_mb` | Explicit cap in MB; overrides the derived one |
| `parameter_group_family` | RDS parameter group family, e.g. `postgres17` |
| `manage_parameter_group` | Set `false` if another stack owns the group |
| `manage_secret` / `secret_name` | Create a new secret (or `manage_secret = false` to write nothing) |
| `existing_secret_name` | Write into an existing secret instead - see [decisions.md](docs/decisions.md#2-where-the-credentials-go-secret-handling) |
| `replica_identity_lock_timeout_ms` | Fail fast instead of hanging on a busy table (default 10 s) |
| `use_rds_replication_role` | `true` for RDS (`rds_replication`), `false` for self-managed |

## Permissions

- **Admin user** must **own, or be a member of the role that owns, every published table** - Postgres
  requires ownership for `ALTER TABLE ... REPLICA IDENTITY` and for adding a table to a publication.
  On RDS the master user is not a superuser, so run `GRANT <owner_role> TO <admin_user>;` once.
  `scripts/preflight.sh` checks this and prints the statement.
- **Replication user** (created by the module) only needs login, replication and `SELECT`.
- **Terraform's AWS role** needs rights on the parameter group and the secret - see
  [decisions.md](docs/decisions.md#2-where-the-credentials-go-secret-handling).

## WAL cap: the tradeoff

`max_slot_wal_keep_size` bounds how much WAL a replication slot may hold back. If the consumer (the
Lakeflow gateway) is offline long enough to exceed it, Postgres **invalidates the slot** and the
pipeline needs a **full re-snapshot** of the affected tables. A larger cap means more disk risk; a
smaller cap means more re-snapshot risk. Size it to your storage and the outage you want to survive,
and alert on slot lag. The 15% default is a starting point, not a recommendation.

## Ownership rules

- The module only **creates** the parameter group; it cannot attach it to an instance owned
  elsewhere. Pass `parameter_group_name` to whatever stack owns the instance.
- Two stacks must not own one secret. In existing-secret mode the module never creates the secret.
- `prevent_destroy` on the slot is intentional: recreating it loses the WAL position.
- Code is the source of truth for the publication: a table added by hand and not declared is removed
  on the next apply.

## Connectivity and security

- `terraform plan` and `apply` need direct network access to the database, so run them on
  self-hosted, VPC-connected runners - hosted runners cannot reach a private database. `psql` must
  be installed there. Run `scripts/preflight.sh` from that machine first.
- **Do not attach self-hosted runners to a public repository.** This repo ships no such workflow.
- The generated password and the admin password live in Terraform state. Use an encrypted remote
  backend and restrict who can read it.
- Table and schema names are validated against a strict identifier regex before reaching SQL.

## Verification

`scripts/verify.sh` is read-only and checks: `wal_level = logical`, the replication user and its
privilege, `SELECT` on every published table, the publication and its members, the slot (`pgoutput`),
`REPLICA IDENTITY FULL` on declared tables, the cap value, and - the check that catches the original
failure - **any published table with no primary key and no `REPLICA IDENTITY FULL`**. A query that
errors is reported as a failure, never as a pass.

```bash
export PGHOST=... PGDATABASE=... PGUSER=... PGPASSWORD=...
REPL_USER=lakeflow_replication PUBLICATION=lakeflow_publication SLOT=lakeflow_slot \
TABLES=public.customer,public.order PKLESS_TABLES=public.order_line \
scripts/verify.sh
```

## Known gaps

- **Not run against real RDS or AWS.** Tested against a local PostgreSQL 16 imitating RDS and
  against mocked providers. Real-RDS behaviour of `rds_replication`, publications and slots is
  unconfirmed until a real dev apply.
- **`max_slot_wal_keep_size`:** that it is accepted as an RDS parameter in MB, and not via
  `ALTER SYSTEM` (which RDS disallows), should be confirmed for your engine version.
- **`scripts/reboot.sh`** decision logic is tested with a stubbed `aws`; the real `describe-db-instances`
  query and the reboot itself have not been exercised.
- **Secrets Manager modes** are tested with mocked providers only; the IAM policy in the decisions
  doc is a starting point.
- **`REPLICA IDENTITY` drift** is not detected by `terraform plan`; `verify.sh` detects it.
- **Aurora is not supported.** The Aurora code paths are commented out in the module, tests and
  example so they can be restored later.
- Open design questions (inputs, module location): see [docs/decisions.md](docs/decisions.md).
- No license file is included yet; add one before others reuse this.

## Development

```bash
cd modules/postgres_cdc_source
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test          # mocked providers - no AWS or database needed
shellcheck ../../scripts/*.sh
```

Terraform versions: the module itself needs `>= 1.9` (it validates on 1.9.8), but the **test suite needs
`>= 1.11`** (it uses `override_during`). Real applies were exercised on 1.15.8.
