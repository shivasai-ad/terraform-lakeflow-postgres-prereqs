variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "enable_postgres_objects" {
  type        = bool
  default     = false
  description = "false = Phase 1 (AWS layer). true = Phase 2 (Postgres objects), only after the reboot."
}

# Aurora support is disabled (RDS for PostgreSQL only).
# variable "is_aurora" {
#   type    = bool
#   default = false
# }

variable "parameter_group_family" {
  type    = string
  default = "postgres17"
}

variable "allocated_storage_gb" {
  type    = number
  default = null
}

variable "host" {
  type = string
}

variable "port" {
  type    = number
  default = 5432
}

variable "database" {
  type = string
}

variable "admin_username" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "publication_tables" {
  type = list(string)
}

variable "replica_identity_full_tables" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
