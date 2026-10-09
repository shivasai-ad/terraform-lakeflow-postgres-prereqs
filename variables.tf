variable "region" {
  type        = string
  default     = "eu-central-1"
  description = "AWS region of the database."
}

variable "name" {
  type        = string
  description = "Short identifier for this source (e.g. a team or domain). Used in resource names."
}

variable "environment" {
  type        = string
  description = "Environment name (dev, qa, sim, prd)."
}

variable "enable_postgres_objects" {
  type        = bool
  default     = false
  description = "false = Phase 1 (parameter group only). true = Phase 2 (Postgres objects, password, secret), only after the parameter group is attached and the instance rebooted."
}

variable "manage_parameter_group" {
  type        = bool
  default     = true
  description = "Create the parameter group. Set false if another stack owns it."
}

variable "parameter_group_family" {
  type        = string
  default     = "postgres17"
  description = "RDS parameter group family."
}

variable "allocated_storage_gb" {
  type        = number
  default     = null
  description = "Allocated storage in GB; derives the WAL retention cap (15% by default)."
}

variable "max_slot_wal_keep_size_mb" {
  type        = number
  default     = null
  description = "Explicit WAL retention cap in MB; overrides the storage-derived value."
}

variable "host" {
  type        = string
  description = "Database endpoint hostname."
}

variable "port" {
  type        = number
  default     = 5432
  description = "Database port."
}

variable "database" {
  type        = string
  description = "Database name."
}

variable "admin_username" {
  type        = string
  description = "Admin (master) user Terraform connects as. Must own, or be a member of the owner of, every published table."
}

variable "admin_password" {
  type        = string
  sensitive   = true
  description = "Admin password. Never put it in a tfvars file; use TF_VAR_admin_password."
}

variable "sslmode" {
  type        = string
  default     = "require"
  description = "sslmode for the postgresql provider and the psql step."
}

variable "table_owner" {
  type        = string
  default     = null
  description = "Role that creates the tables (default SELECT for the replication user). Set to your application's table-owner role."
}

variable "publication_tables" {
  type        = list(string)
  description = "Schema-qualified tables to publish, e.g. [\"public.orders\"]."
}

variable "replica_identity_full_tables" {
  type        = list(string)
  default     = []
  description = "Tables without a primary key (or with TOAST-able columns). Subset of publication_tables."
}

variable "manage_secret" {
  type        = bool
  default     = true
  description = "Write the credentials to Secrets Manager. false = write nothing."
}

variable "secret_name" {
  type        = string
  default     = null
  description = "Name for the NEW secret (default mode). Do not combine with existing_secret_name."
}

variable "existing_secret_name" {
  type        = string
  default     = null
  description = "Write the credentials into this EXISTING secret instead of creating one. See docs/decisions.md, section 2."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to AWS resources."
}
