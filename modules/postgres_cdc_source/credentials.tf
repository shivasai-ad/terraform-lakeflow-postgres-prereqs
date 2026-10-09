# Phase 2 only - the replication password and where it is stored.
#
# Nothing here exists in Phase 1, so a consumer can never read an empty secret
# or credentials that do not work yet.
#
# Two ways to store the credentials (when manage_secret = true):
#
#   1. New secret (default): the module creates a secret it owns and writes the
#      credentials into it. No ownership conflict.
#
#   2. Existing secret (existing_secret_name set): the module never creates the
#      secret, so there is no "already exists" error and no second owner of the
#      secret itself. It looks the secret up and writes ONE new version whose
#      JSON is the existing content with username/password replaced by the
#      replication user's. Other keys are preserved. This changes what every
#      reader of that secret sees - see docs/decisions.md, section 2.

locals {
  creds_enabled       = var.enable_postgres_objects
  use_existing_secret = var.existing_secret_name != null
  write_secret        = var.manage_secret && local.creds_enabled
  create_secret       = local.write_secret && !local.use_existing_secret
  lookup_secret       = local.write_secret && local.use_existing_secret

  secret_name = coalesce(var.secret_name, "cdc/${var.name}-replication-${var.environment}")

  replication_creds = {
    username = var.replication_username
    password = try(random_password.replication[0].result, null)
  }

  new_secret_json = jsonencode(merge(
    {
      host     = var.host
      port     = var.port
      database = var.database
    },
    local.replication_creds
  ))

  # Defaults only where the existing secret has no value; existing keys win;
  # username/password always come from the replication user. The for-expression
  # yields a single decoded object (or nothing), so a malformed existing secret
  # fails loudly in jsondecode instead of being silently overwritten.
  merged_secret_json = jsonencode(merge(concat(
    [{
      host     = var.host
      port     = var.port
      database = var.database
    }],
    [for v in data.aws_secretsmanager_secret_version.existing : jsondecode(v.secret_string)],
    [local.replication_creds]
  )...))
}

resource "random_password" "replication" {
  count   = local.creds_enabled ? 1 : 0
  length  = 32
  special = false
}

data "aws_secretsmanager_secret" "existing" {
  count = local.lookup_secret ? 1 : 0
  name  = var.existing_secret_name
}

data "aws_secretsmanager_secret_version" "existing" {
  count     = local.lookup_secret ? 1 : 0
  secret_id = data.aws_secretsmanager_secret.existing[0].id
}

resource "aws_secretsmanager_secret" "replication" {
  count = local.create_secret ? 1 : 0
  name  = local.secret_name
  tags  = var.tags
}

# Written after the role exists, so the secret only ever holds working credentials.
resource "aws_secretsmanager_secret_version" "replication" {
  count         = local.write_secret ? 1 : 0
  secret_id     = local.use_existing_secret ? data.aws_secretsmanager_secret.existing[0].id : aws_secretsmanager_secret.replication[0].id
  secret_string = local.use_existing_secret ? local.merged_secret_json : local.new_secret_json

  depends_on = [postgresql_role.replication]
}
