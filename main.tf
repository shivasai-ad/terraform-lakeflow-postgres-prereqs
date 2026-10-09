# One run of this root = one source database = one state file.
# Per-environment settings live in envs/<environment>.tfvars. The postgresql
# provider is configured once here (provider blocks cannot be driven by
# for_each), so another source or environment means another tfvars file and
# another state key - not another provider alias.

provider "aws" {
  region = var.region
}

provider "postgresql" {
  host      = var.host
  port      = var.port
  database  = var.database
  username  = var.admin_username
  password  = var.admin_password
  sslmode   = var.sslmode
  superuser = false # RDS master users are not true superusers
}

module "cdc_source" {
  source = "./modules/postgres_cdc_source"

  name        = var.name
  environment = var.environment

  enable_postgres_objects = var.enable_postgres_objects

  manage_parameter_group    = var.manage_parameter_group
  parameter_group_family    = var.parameter_group_family
  allocated_storage_gb      = var.allocated_storage_gb
  max_slot_wal_keep_size_mb = var.max_slot_wal_keep_size_mb

  host           = var.host
  port           = var.port
  database       = var.database
  admin_username = var.admin_username
  admin_password = var.admin_password
  sslmode        = var.sslmode

  table_owner                  = var.table_owner
  publication_tables           = var.publication_tables
  replica_identity_full_tables = var.replica_identity_full_tables

  manage_secret        = var.manage_secret
  secret_name          = var.secret_name
  existing_secret_name = var.existing_secret_name

  tags = var.tags
}
