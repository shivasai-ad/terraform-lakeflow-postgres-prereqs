# dev environment - non-secret settings only.
# The admin password is never stored here; supply it from the environment:
#   export TF_VAR_admin_password=...
#
# Another environment or source = another file here (e.g. envs/qa.tfvars) plus its own
# state key at init time. Keep one state per file.

region      = "eu-central-1"
name        = "orders"
environment = "dev"

# Phase 1: false. Flip to true only after the parameter group is attached to the
# instance and the instance has been rebooted (see README).
enable_postgres_objects = false

parameter_group_family = "postgres17"
allocated_storage_gb   = 110 # drives the WAL retention cap (15% by default)

# TODO: replace with the real dev RDS endpoint and database.
host           = "orders-db.example.eu-central-1.rds.amazonaws.com"
database       = "orders"
admin_username = "postgres"

# Role that creates the tables. The admin user must own, or be a member of the owner of,
# every published table - run scripts/preflight.sh before applying.
# table_owner = "app_owner"

publication_tables = [
  "public.customer",
  "public.order",
  "public.order_line",
]

# Tables without a primary key (or with TOAST-able columns). Subset of publication_tables.
replica_identity_full_tables = [
  "public.order_line",
]

# Write the credentials into an EXISTING secret (owned by another stack) instead of creating
# one. Replaces username/password in it and keeps other keys. See docs/decisions.md, section 2.
# existing_secret_name = "team/orders-rds-credentials-dev"

tags = {
  Environment = "dev"
  ManagedBy   = "terraform"
}
