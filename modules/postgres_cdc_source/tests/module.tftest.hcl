mock_provider "aws" {}
mock_provider "random" {}
mock_provider "postgresql" {}

variables {
  name               = "orders"
  environment        = "dev"
  host               = "db.example.internal"
  database           = "orders"
  admin_username     = "postgres"
  admin_password     = "not-a-real-password"
  publication_tables = ["public.customer", "public.order_line"]
}

run "phase1_creates_only_aws_layer" {
  command = plan

  variables {
    allocated_storage_gb = 110
  }

  assert {
    condition     = length(aws_db_parameter_group.this) == 1
    error_message = "Phase 1 should create the RDS parameter group."
  }

  assert {
    condition     = length(postgresql_role.replication) == 0 && length(postgresql_publication.this) == 0 && length(postgresql_replication_slot.this) == 0
    error_message = "Phase 1 must not create any Postgres objects."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.replication) == 0 && length(aws_secretsmanager_secret_version.replication) == 0
    error_message = "No secret should exist in Phase 1, so a consumer never reads an empty or non-working secret."
  }

  assert {
    condition     = output.max_slot_wal_keep_size_mb == 16896
    error_message = "110 GB at 15% should give a 16896 MB cap."
  }
}

run "explicit_wal_cap_overrides_storage_derived_value" {
  command = plan

  variables {
    allocated_storage_gb      = 110
    max_slot_wal_keep_size_mb = 20480
  }

  assert {
    condition     = output.max_slot_wal_keep_size_mb == 20480
    error_message = "An explicit cap must win over the storage-derived one."
  }
}

run "phase2_creates_postgres_objects" {
  command = plan

  variables {
    enable_postgres_objects      = true
    allocated_storage_gb         = 110
    replica_identity_full_tables = ["public.order_line"]
  }

  assert {
    condition     = length(postgresql_role.replication) == 1 && length(postgresql_grant_role.rds_replication) == 1
    error_message = "Phase 2 should create the replication role and the rds_replication grant."
  }

  assert {
    condition     = length(postgresql_publication.this) == 1 && length(postgresql_replication_slot.this) == 1
    error_message = "Phase 2 should create the publication and the slot."
  }

  assert {
    condition     = length(terraform_data.replica_identity) == 1
    error_message = "One REPLICA IDENTITY step is expected per PK-less table."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.replication) == 1 && length(aws_secretsmanager_secret_version.replication) == 1
    error_message = "Phase 2 should create the secret and write the credentials."
  }
}

run "non_rds_uses_replication_attribute" {
  command = plan

  variables {
    enable_postgres_objects  = true
    allocated_storage_gb     = 110
    use_rds_replication_role = false
  }

  assert {
    condition     = length(postgresql_grant_role.rds_replication) == 0 && postgresql_role.replication[0].replication == true
    error_message = "Self-managed Postgres should use the REPLICATION attribute, not rds_replication."
  }
}

# Aurora support is disabled (see main.tf). Re-enable these with it.
#
# run "aurora_uses_cluster_parameter_group" {
#   command = plan
#
#   variables {
#     is_aurora                 = true
#     parameter_group_family    = "aurora-postgresql16"
#     max_slot_wal_keep_size_mb = 10240
#   }
#
#   assert {
#     condition     = length(aws_rds_cluster_parameter_group.this) == 1 && length(aws_db_parameter_group.this) == 0
#     error_message = "Aurora should get a cluster parameter group only."
#   }
# }
#
# run "aurora_without_cap_skips_the_parameter" {
#   command = plan
#
#   variables {
#     is_aurora              = true
#     parameter_group_family = "aurora-postgresql16"
#   }
#
#   assert {
#     condition     = output.max_slot_wal_keep_size_mb == null
#     error_message = "Without storage or an explicit cap, Aurora should apply no cap parameter."
#   }
# }

run "rds_without_any_wal_cap_is_rejected" {
  command = plan

  expect_failures = [aws_db_parameter_group.this]
}

run "pk_less_table_must_be_published" {
  command = plan

  variables {
    allocated_storage_gb         = 110
    replica_identity_full_tables = ["public.not_published"]
  }

  expect_failures = [var.replica_identity_full_tables]
}

run "table_names_are_validated_against_injection" {
  command = plan

  variables {
    allocated_storage_gb = 110
    publication_tables   = ["public.x\"; DROP TABLE users; --"]
  }

  expect_failures = [var.publication_tables]
}

run "unlimited_wal_is_not_allowed" {
  command = plan

  variables {
    max_slot_wal_keep_size_mb = -1
  }

  expect_failures = [var.max_slot_wal_keep_size_mb]
}

run "pk_less_tables_need_admin_password" {
  command = plan

  variables {
    enable_postgres_objects      = true
    allocated_storage_gb         = 110
    admin_password               = null
    replica_identity_full_tables = ["public.order_line"]
  }

  expect_failures = [terraform_data.replica_identity]
}
