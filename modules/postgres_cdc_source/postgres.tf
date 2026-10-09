# Layer 2 - Postgres objects. Created only when enable_postgres_objects = true
# (Phase 2), because a logical replication slot cannot be created until logical
# replication is active, i.e. after the parameter group is attached and the
# instance has been rebooted.

locals {
  pg_enabled = var.enable_postgres_objects
  owner      = coalesce(var.table_owner, var.admin_username)

  # Safe to interpolate into SQL: table names are validated against a strict
  # identifier regex in variables.tf.
  replica_identity_sql = {
    for t in var.replica_identity_full_tables :
    t => "ALTER TABLE \"${split(".", t)[0]}\".\"${split(".", t)[1]}\" REPLICA IDENTITY FULL"
  }
}

resource "postgresql_role" "replication" {
  count       = local.pg_enabled ? 1 : 0
  name        = var.replication_username
  login       = true
  password    = random_password.replication[0].result
  replication = !var.use_rds_replication_role

  # Membership MUST be declared here, not with a separate postgresql_grant_role:
  # this resource treats `roles` as the complete set of memberships, so a separate
  # grant is revoked on every apply and re-added on the next (never idempotent).
  roles = var.use_rds_replication_role ? ["rds_replication"] : []
}

resource "postgresql_grant" "schema_usage" {
  for_each    = local.pg_enabled ? toset(var.schemas) : toset([])
  database    = var.database
  role        = postgresql_role.replication[0].name
  schema      = each.value
  object_type = "schema"
  privileges  = ["USAGE"]
}

resource "postgresql_grant" "tables_select" {
  for_each    = local.pg_enabled ? toset(var.schemas) : toset([])
  database    = var.database
  role        = postgresql_role.replication[0].name
  schema      = each.value
  object_type = "table"
  objects     = [] # empty = all existing tables in the schema
  privileges  = ["SELECT"]
}

resource "postgresql_default_privileges" "tables_select" {
  for_each    = local.pg_enabled ? toset(var.schemas) : toset([])
  database    = var.database
  role        = postgresql_role.replication[0].name
  schema      = each.value
  owner       = local.owner
  object_type = "table"
  privileges  = ["SELECT"]
}

resource "postgresql_publication" "this" {
  count    = local.pg_enabled ? 1 : 0
  name     = var.publication_name
  database = var.database
  tables   = var.publication_tables
}

# prevent_destroy: destroying and recreating the slot loses the WAL position and
# forces a full re-snapshot. Removing it must be a conscious act.
resource "postgresql_replication_slot" "this" {
  count    = local.pg_enabled ? 1 : 0
  name     = var.slot_name
  plugin   = "pgoutput"
  database = var.database

  depends_on = [postgresql_publication.this]

  lifecycle {
    prevent_destroy = true
  }
}

# No native Terraform resource exists for REPLICA IDENTITY, so this runs an
# idempotent ALTER TABLE through psql (needs psql on the machine running apply).
# It re-runs only when the table, database or endpoint changes - use
# scripts/verify.sh to detect out-of-band drift.
resource "terraform_data" "replica_identity" {
  for_each         = local.pg_enabled ? toset(var.replica_identity_full_tables) : toset([])
  triggers_replace = [each.value, var.database, var.host, var.port]

  provisioner "local-exec" {
    # -X: ignore any psqlrc. -w: never prompt for a password (fail instead of hanging CI).
    # lock_timeout: fail fast if a busy table blocks the brief lock this ALTER needs.
    command = "psql -X -w -v ON_ERROR_STOP=1 -c 'SET lock_timeout = ${var.replica_identity_lock_timeout_ms}; ${local.replica_identity_sql[each.value]}'"
    environment = {
      PGHOST            = var.host
      PGPORT            = tostring(var.port)
      PGDATABASE        = var.database
      PGUSER            = var.admin_username
      PGPASSWORD        = var.admin_password
      PGSSLMODE         = var.sslmode
      PGCONNECT_TIMEOUT = "10"
    }
  }

  lifecycle {
    precondition {
      condition     = var.admin_password != null
      error_message = "admin_password is required when replica_identity_full_tables is not empty."
    }
  }

  depends_on = [postgresql_publication.this]
}
