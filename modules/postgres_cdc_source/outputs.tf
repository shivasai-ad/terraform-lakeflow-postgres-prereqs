output "parameter_group_name" {
  description = "Name of the managed parameter group. Attach it to the instance, then reboot (scripts/reboot.sh). Null when manage_parameter_group = false."
  value = try(
    aws_db_parameter_group.this[0].name,
    # aws_rds_cluster_parameter_group.this[0].name, # Aurora (disabled)
    null
  )
}

output "max_slot_wal_keep_size_mb" {
  description = "WAL retention cap applied (MB)."
  value       = local.wal_cap_mb
}

output "replication_username" {
  value = var.replication_username
}

output "publication_name" {
  value = var.publication_name
}

output "slot_name" {
  value = var.slot_name
}

output "secret_arn" {
  description = "ARN of the credentials secret. Null when manage_secret = false."
  value       = try(aws_secretsmanager_secret.replication[0].arn, null)
}

output "replication_password" {
  description = "Generated replication password. Use only when manage_secret = false and you write it to your own secret store."
  value       = random_password.replication.result
  sensitive   = true
}

output "expected_state" {
  description = "What scripts/verify.sh should find in the database after Phase 2. Also the Step-7 verification contract."
  value = {
    wal_level                    = "logical"
    replication_username         = var.replication_username
    use_rds_replication_role     = var.use_rds_replication_role
    publication_name             = var.publication_name
    publication_tables           = var.publication_tables
    slot_name                    = var.slot_name
    slot_plugin                  = "pgoutput"
    replica_identity_full_tables = var.replica_identity_full_tables
    max_slot_wal_keep_size_mb    = local.wal_cap_mb
  }
}

output "next_step" {
  description = "What to do next, based on the current phase."
  value = var.enable_postgres_objects ? (
    "Phase 2 applied. Run scripts/verify.sh to confirm the database state."
    ) : (
    "Phase 1 applied. Attach parameter_group_name to the instance, run scripts/reboot.sh, confirm wal_level=logical, then re-apply with enable_postgres_objects = true."
  )
}
