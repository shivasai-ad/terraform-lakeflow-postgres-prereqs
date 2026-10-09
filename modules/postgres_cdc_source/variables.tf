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
    Phase gate. false (default) = Phase 1: only the parameter group.
    true = Phase 2: also create the Postgres objects (role, grants, publication, slot,
    REPLICA IDENTITY) plus the password and the secret.
    Only set true AFTER logical replication is active, i.e. after the
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
  description = <<-EOT
    Admin (master) username Terraform connects as. It must OWN, or be a member of the role that
    owns, every table in publication_tables - Postgres requires table ownership for both
    ALTER TABLE ... REPLICA IDENTITY and adding a table to a publication. RDS's master user is
    not a true superuser, so if an application role owns the tables run once:
    GRANT <owner_role> TO <admin_username>;   (scripts/preflight.sh checks this)
  EOT
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

variable "replica_identity_lock_timeout_ms" {
  type        = number
  default     = 10000
  description = "lock_timeout (ms) for the REPLICA IDENTITY ALTER TABLE. If a busy table holds a conflicting lock longer than this, the step fails instead of hanging the pipeline; re-run at a quieter time."

  validation {
    condition     = floor(var.replica_identity_lock_timeout_ms) == var.replica_identity_lock_timeout_ms && var.replica_identity_lock_timeout_ms >= 100 && var.replica_identity_lock_timeout_ms <= 600000
    error_message = "replica_identity_lock_timeout_ms must be a whole number between 100 and 600000."
  }
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
  description = "Role that CREATES the tables; the replication user gets default SELECT on tables this role creates later. Set it to your application's table-owner role - the default (admin_username) only covers tables the admin itself creates."
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
    Create (in Phase 2) an AWS Secrets Manager secret holding the replication credentials as JSON
    {host, port, username, password, database}. Set false if the secret is owned by another
    stack - then read the sensitive replication_password output and write it there yourself.
  EOT
}

variable "secret_name" {
  type        = string
  default     = null
  description = "Name for the NEW secret the module creates. Defaults to cdc/<name>-replication-<environment>. Do not combine with existing_secret_name."
}

variable "existing_secret_name" {
  type        = string
  default     = null
  description = <<-EOT
    Name or ARN of an EXISTING secret (owned by another stack) to write the replication
    credentials into, instead of creating a new one. The module only looks it up and writes
    one new version: the existing JSON with username/password replaced and other keys kept.
    The secret must already hold a JSON value. The Terraform role needs
    secretsmanager:DescribeSecret/GetSecretValue/PutSecretValue on it (plus KMS access if it
    uses a customer-managed key). WARNING: every reader of that secret will then see the
    replication user instead of whatever user it held before.
  EOT

  validation {
    condition     = var.existing_secret_name == null ? true : var.secret_name == null
    error_message = "Set either secret_name (create a new secret) or existing_secret_name (write into an existing one), not both."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to AWS resources."
}
