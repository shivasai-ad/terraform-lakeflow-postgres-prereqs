# Layer 1 - AWS: parameter group (logical replication + WAL cap), generated
# password, and the credentials secret.
#
# The module never reboots anything. Static parameters only take effect after a
# reboot, which is a deliberate, separate step (scripts/reboot.sh).

locals {
  wal_cap_mb = (
    var.max_slot_wal_keep_size_mb != null ? var.max_slot_wal_keep_size_mb :
    var.allocated_storage_gb != null ? floor(var.allocated_storage_gb * 1024 * var.wal_retention_percent / 100) :
    null
  )

  parameters = concat(
    [{ name = "rds.logical_replication", value = "1" }],
    local.wal_cap_mb != null ? [{ name = "max_slot_wal_keep_size", value = tostring(local.wal_cap_mb) }] : []
  )

  base_name   = "${var.name}-${var.environment}-cdc"
  secret_name = coalesce(var.secret_name, "cdc/${var.name}-replication-${var.environment}")
}

resource "aws_db_parameter_group" "this" {
  count       = var.manage_parameter_group ? 1 : 0 # Aurora disabled; was: && !var.is_aurora
  name_prefix = "${local.base_name}-"
  family      = var.parameter_group_family
  description = "Logical replication prerequisites for Lakeflow Connect CDC (${var.name}/${var.environment})"
  tags        = var.tags

  dynamic "parameter" {
    for_each = local.parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = "pending-reboot"
    }
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = local.wal_cap_mb != null
      error_message = "Set allocated_storage_gb or max_slot_wal_keep_size_mb so a WAL retention cap can be applied."
    }
  }
}

# Aurora support is disabled: this project targets RDS for PostgreSQL. To restore it,
# uncomment this resource and the is_aurora variable, and add "&& !var.is_aurora" back to
# the count of aws_db_parameter_group.this above.
#
# resource "aws_rds_cluster_parameter_group" "this" {
#   count       = var.manage_parameter_group && var.is_aurora ? 1 : 0
#   name_prefix = "${local.base_name}-"
#   family      = var.parameter_group_family
#   description = "Logical replication prerequisites for Lakeflow Connect CDC (${var.name}/${var.environment})"
#   tags        = var.tags
#
#   dynamic "parameter" {
#     for_each = local.parameters
#     content {
#       name         = parameter.value.name
#       value        = parameter.value.value
#       apply_method = "pending-reboot"
#     }
#   }
#
#   lifecycle {
#     create_before_destroy = true
#   }
# }

resource "random_password" "replication" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "replication" {
  count = var.manage_secret && var.enable_postgres_objects ? 1 : 0
  name  = local.secret_name
  tags  = var.tags
}

# Written only in Phase 2, once the role actually exists, so consumers never see
# credentials that do not work yet.
resource "aws_secretsmanager_secret_version" "replication" {
  count     = var.manage_secret && var.enable_postgres_objects ? 1 : 0
  secret_id = aws_secretsmanager_secret.replication[0].id

  secret_string = jsonencode({
    host     = var.host
    port     = var.port
    username = var.replication_username
    password = random_password.replication.result
    database = var.database
  })

  depends_on = [postgresql_role.replication]
}
