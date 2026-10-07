# One run of this root = one source database = one state file. The postgresql
# provider is configured once here, so onboarding another source means another
# tfvars file and another state key, not another provider alias.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.22.0"
    }
  }

  # Configure your own backend, with a distinct key per source, e.g.
  #   terraform init -backend-config="key=<env>/<source>/cdc-prereqs.tfstate"
  backend "s3" {}
}

provider "aws" {
  region = var.region
}

provider "postgresql" {
  host      = var.host
  port      = var.port
  database  = var.database
  username  = var.admin_username
  password  = var.admin_password
  sslmode   = "require"
  superuser = false # RDS master users are not true superusers
}

module "cdc_source" {
  source = "../../modules/postgres_cdc_source"

  name        = var.name
  environment = var.environment

  enable_postgres_objects = var.enable_postgres_objects

  # is_aurora            = var.is_aurora # Aurora support disabled
  parameter_group_family = var.parameter_group_family
  allocated_storage_gb   = var.allocated_storage_gb

  host           = var.host
  port           = var.port
  database       = var.database
  admin_username = var.admin_username
  admin_password = var.admin_password

  publication_tables           = var.publication_tables
  replica_identity_full_tables = var.replica_identity_full_tables

  tags = var.tags
}

output "parameter_group_name" {
  value = module.cdc_source.parameter_group_name
}

output "expected_state" {
  value = module.cdc_source.expected_state
}

output "next_step" {
  value = module.cdc_source.next_step
}
