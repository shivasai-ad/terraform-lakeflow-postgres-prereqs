# Copy to <source>.tfvars. Never commit real values. Pass the admin password via
# the environment instead of this file:  export TF_VAR_admin_password=...

name        = "orders"
environment = "dev"

# Phase 1: leave false. Flip to true only after the reboot (see README).
enable_postgres_objects = false

# is_aurora            = false # Aurora support disabled
parameter_group_family = "postgres17"
allocated_storage_gb   = 110 # drives the WAL retention cap (15% by default)

host           = "orders-db.example.eu-central-1.rds.amazonaws.com"
database       = "orders"
admin_username = "postgres"

publication_tables = [
  "public.customer",
  "public.order",
  "public.order_line",
]

# Tables without a primary key (or with TOAST-able columns). Subset of publication_tables.
replica_identity_full_tables = [
  "public.order_line",
]

# Role that creates the tables; the replication user gets default SELECT on its future tables.
# The admin user must own (or be a member of the owner of) every published table - run
# scripts/preflight.sh before applying.
# table_owner = "app_owner"

# Write the credentials into an EXISTING secret (owned by another stack) instead of creating one.
# Replaces username/password in it and keeps other keys. See docs/decisions.md, Decision 2.
# existing_secret_name = "team/orders-rds-credentials-dev"
