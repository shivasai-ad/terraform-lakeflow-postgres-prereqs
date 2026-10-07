########################################
# Identity / naming
########################################

variable "name" {
  type        = string
  description = "Short identifier for this source (e.g. a team or domain name). Used in resource names."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be lowercase alphanumeric/hyphen, 2-41 chars, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. dev, qa, sim, prd). Used in resource names."
}

########################################
# Phase gate (see README: two-phase apply)
########################################

variable "enable_postgres_objects" {
  type        = bool
  default     = false
  description = <<-EOT
    Phase gate. false (default) = Phase 1: only the AWS layer (parameter group, secret).
    true = Phase 2: also create the Postgres objects (role, grants, publication, slot,
    REPLICA IDENTITY). Only set true AFTER logical replication is active, i.e. after the
    parameter group is attached and the instance has been rebooted - creating a logical
    replication slot fails otherwise.
  EOT
}

########################################
# Layer 1: AWS parameter group
########################################

variable "manage_parameter_group" {
  type        = bool
  default     = true
  description = <<-EOT
    Create and manage a parameter group with the CDC parameters. The module only creates the
    group; the consumer must attach it to the instance (the instance is usually owned
    elsewhere). Set false if the group is owned elsewhere - then you must set the parameters
    yourself and the module will not touch it.
  EOT
}

# Aurora support is disabled: this project targets RDS for PostgreSQL. Uncomment together
# with aws_rds_cluster_parameter_group in main.tf to restore it.
#
# variable "is_aurora" {
#   type        = bool
#   default     = false
#   description = "true = Aurora PostgreSQL (cluster parameter group); false = RDS for PostgreSQL (instance parameter group)."
# }

variable "parameter_group_family" {
  type        = string
  default     = "postgres17"
  description = "Parameter group family for RDS for PostgreSQL, e.g. postgres17."
}

variable "allocated_storage_gb" {
  type        = number
  default     = null
  description = <<-EOT
    Allocated storage of the instance in GB. Used to derive the WAL retention cap when
    max_slot_wal_keep_size_mb is not set.
  EOT

  validation {
    condition     = var.allocated_storage_gb == null ? true : var.allocated_storage_gb > 0
    error_message = "allocated_storage_gb must be > 0."
  }
}

variable "wal_retention_percent" {
  type        = number
  default     = 15
  description = "Percent of allocated storage to allow replication slots to retain as WAL (when max_slot_wal_keep_size_mb is not set)."

  validation {
    condition     = var.wal_retention_percent > 0 && var.wal_retention_percent <= 50
    error_message = "wal_retention_percent must be between 1 and 50 - a larger cap risks filling the disk."
  }
}

variable "max_slot_wal_keep_size_mb" {
  type        = number
  default     = null
  description = "Explicit WAL retention cap in MB (RDS parameter unit). Overrides the storage-derived value."

  validation {
    condition     = var.max_slot_wal_keep_size_mb == null ? true : var.max_slot_wal_keep_size_mb > 0
    error_message = "max_slot_wal_keep_size_mb must be > 0 (-1, unlimited, is deliberately not allowed)."
  }
}

########################################
# Connection details (used for the secret + REPLICA IDENTITY step)
########################################

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
  description = "Database name that contains the tables to replicate."
}

variable "admin_username" {
  type        = string
  description = "Admin (master) username. Used for the REPLICA IDENTITY step and as the default owner for default privileges."
}

variable "admin_password" {
  type        = string
  sensitive   = true
  default     = null
  description = "Admin password. Only needed when replica_identity_full_tables is non-empty (passed to psql via PGPASSWORD)."
}

variable "sslmode" {
  type        = string
  default     = "require"
  description = "psql sslmode for the REPLICA IDENTITY step."
}

########################################
# Layer 2: Postgres objects
########################################

variable "replication_username" {
  type        = string
  default     = "lakeflow_replication"
  description = "Name of the dedicated replication user."

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]{0,62}$", var.replication_username))
    error_message = "replication_username must be a simple lowercase Postgres identifier."
  }
}

variable "use_rds_replication_role" {
  type        = bool
  default     = true
  description = <<-EOT
    true (RDS) = grant the rds_replication role instead of setting the REPLICATION
    attribute, because the master user is not a true superuser on RDS. false = set REPLICATION
    on the role (self-managed Postgres).
  EOT
}

variable "schemas" {
  type        = list(string)
  default     = ["public"]
  description = "Schemas the replication user gets USAGE + SELECT (and default SELECT on future tables) on."

  validation {
    condition     = alltrue([for s in var.schemas : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", s))])
    error_message = "schemas must be simple identifiers."
  }
}

variable "table_owner" {
  type        = string
  default     = null
  description = "Role that owns/creates the tables, for ALTER DEFAULT PRIVILEGES. Defaults to admin_username."
}

variable "publication_name" {
  type        = string
  default     = "lakeflow_publication"
  description = "Publication name."
}

variable "publication_tables" {
  type        = list(string)
  description = "Explicit list of schema-qualified tables to publish (e.g. [\"public.orders\"]). An explicit list is used instead of FOR ALL TABLES to avoid unnecessary WAL growth."

  validation {
    condition     = length(var.publication_tables) > 0
    error_message = "publication_tables must not be empty."
  }

  validation {
    condition     = alltrue([for t in var.publication_tables : can(regex("^[A-Za-z_][A-Za-z0-9_]*\\.[A-Za-z_][A-Za-z0-9_]*$", t))])
    error_message = "Each table must be schema-qualified and a simple identifier, e.g. public.orders."
  }
}

variable "replica_identity_full_tables" {
  type        = list(string)
  default     = []
  description = "Tables without a primary key (or with TOAST-able columns) that need REPLICA IDENTITY FULL. Must be a subset of publication_tables."

  validation {
    condition     = alltrue([for t in var.replica_identity_full_tables : contains(var.publication_tables, t)])
    error_message = "Every replica_identity_full_tables entry must also be in publication_tables."
  }
}

variable "slot_name" {
  type        = string
  default     = "lakeflow_slot"
  description = "Logical replication slot name. One slot per gateway/source."
}

########################################
# Secret
########################################

variable "manage_secret" {
  type        = bool
  default     = true
  description = <<-EOT
    Create an AWS Secrets Manager secret holding the replication credentials as JSON
    {host, port, username, password, database}. Set false if the secret is owned by another
    stack - then read the sensitive replication_password output and write it there yourself.
  EOT
}

variable "secret_name" {
  type        = string
  default     = null
  description = "Secrets Manager secret name. Defaults to cdc/<name>-replication-<environment>."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to AWS resources."
}
