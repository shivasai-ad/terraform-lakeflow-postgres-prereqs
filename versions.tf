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

  # One state file per environment / source. Supply the location at init time, e.g.
  #   terraform init -backend-config="bucket=<state-bucket>" \
  #                  -backend-config="key=dev/orders/cdc-prereqs.tfstate" \
  #                  -backend-config="region=<region>"
  backend "s3" {}
}
