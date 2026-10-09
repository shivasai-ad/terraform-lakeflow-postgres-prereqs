# Design decisions

What was decided, what the code does about it, and what is still open. "Tested" means
exercised against a local PostgreSQL 16 that imitates RDS (non-superuser admin, tables owned by
another role, an `rds_replication` role) or against mocked providers. Nothing here has been
run against real RDS or real AWS yet.

| # | Question | Status |
|---|---|---|
| 1 | Where does Terraform run? | Decided; needs reachability confirmed per environment |
| 2 | Where do the credentials go? | Both modes implemented; **owner decision needed** |
| 3 | How are the Postgres objects created? | Decided; one documented exception |
| 4 | How is the reboot handled? | Decided; approver and window are organisational |
| 5 | What does each team provide? | Partly open - see the end |
| 6 | Where does the module live? | Open |

---

## 1. Where Terraform runs (connectivity)

**Decision.** `terraform plan` and `apply` run on **self-hosted runners that have a network path to
the database**. Hosted runners can only do `fmt`, `validate` and `test`.

Why: the `postgresql` provider opens a direct TCP connection, and it does so during `plan` too
(to refresh state). A private database has no public address.

Requirements for the runner:

- a network path to the instance (same VPC, or peering / transit gateway / VPN) and working DNS
  for the private endpoint,
- the database security group allows inbound `5432` from the runner,
- `psql` installed (the `REPLICA IDENTITY` step uses it),
- the admin credential, from a secret store (not committed),
- one reachable path **per environment**, which may be different accounts or VPCs.

`scripts/preflight.sh` checks all of this from the runner before an apply and prints the fix for
each failure. Run it first.

**Security note.** Never attach a self-hosted runner to a *public* repository: workflows can be
triggered from forks and would run code on your network. Use a private repo, protected
environments and required reviewers. This repository deliberately ships no self-hosted workflow.

## 2. Where the credentials go (secret handling)

The ticket asks for the generated password to land in the existing per-team secret. Creating a
secret that already exists fails ("already exists"), and two stacks managing one secret fight.

**Implemented - both modes** (`credentials.tf`; nothing exists in Phase 1):

| Mode | How | Use when |
|---|---|---|
| **New secret** (default) | Module creates and owns `cdc/<name>-replication-<env>` (or `secret_name`) | The owner won't share their secret |
| **Existing secret** (`existing_secret_name`) | Module **never creates** it: looks it up and writes one new version = existing JSON with `username`/`password` replaced, other keys kept | The owner agrees; closes the "one source of truth" loop |

Tested with mocked providers: merge keeps unrelated keys and existing `host`, fills missing keys,
replaces only username/password, and never creates the secret.

**Giving the Terraform role access** is necessary but not the whole answer. In the **same AWS
account** the Terraform role's own IAM policy is enough; a secret resource policy is only needed
cross-account. Start from this and adjust using the errors you get:

```json
{
  "Effect": "Allow",
  "Action": [
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetResourcePolicy",
    "secretsmanager:GetSecretValue",
    "secretsmanager:PutSecretValue",
    "secretsmanager:UpdateSecretVersionStage"
  ],
  "Resource": "arn:aws:secretsmanager:<region>:<account>:secret:<name>-*"
}
```

If the secret uses a customer-managed KMS key, also allow `kms:Decrypt` and `kms:GenerateDataKey`
on that key.

Permission does not remove the **ownership** problem. Before using existing-secret mode, agree:

1. The secret must already hold a **JSON** value (a malformed value fails loudly, by design).
2. **Every reader sees the change.** Replacing username/password swaps whatever user it held for
   the replication user. Confirm nothing else depends on the old values.
3. The owning stack must **stop managing the secret's value** (or ignore changes to it), or the two
   stacks overwrite each other on each apply.
4. If anything **rotates** the secret automatically, rotation will overwrite the replication
   user's password.

## 3. How the Postgres objects are created

**Decision.** Native `postgresql` resources for the user, memberships, grants, default privileges,
publication and slot. **One documented exception**: `REPLICA IDENTITY FULL` has no native
resource, so Terraform runs an idempotent `ALTER TABLE` through `psql` during `apply`.

Tested against the local database:

- real `apply` creates all objects; `verify.sh` passes; **re-plan three times says "No changes"**
  and a second apply changes nothing; the slot survives (WAL position kept),
- a bug the mocked tests could not see: a separate `postgresql_grant_role` is revoked and re-added
  by `postgresql_role` on every apply. Membership is now declared on the role itself,
- Terraform also corrects **publication drift**: a table added to the publication by hand and not
  declared in code is removed on the next apply. Code is the source of truth.

**Permission the admin needs.** `ALTER TABLE` and adding a table to a publication both require
*owning* the table (or being a member of its owner). On RDS the master user is not a superuser, so:

```sql
GRANT <table_owner_role> TO <admin_user>;
```

Without it: `ERROR: must be owner of table ...` (reproduced). `preflight.sh` detects this and prints
the exact statement.

**Busy tables.** The `ALTER` needs a lock that conflicts with writers. The step sets
`lock_timeout` (default 10 s, `replica_identity_lock_timeout_ms`) and fails fast with
`canceling statement due to lock timeout` instead of hanging; the failed step is retried on the next
apply. Run it at a quiet time for hot tables.

**Drift on `REPLICA IDENTITY`** is not visible to `terraform plan`. Run `scripts/verify.sh` after
every apply (and ideally on a schedule). It reports declared tables that lost `FULL` **and any
published table with no primary key and no `FULL`** - the failure behind the original incidents
(reproduced: on such a table a plain `UPDATE` on the source fails).

## 4. The reboot

**Decision.** Terraform never reboots anything. Work is split into two phases
(`enable_postgres_objects`), with the reboot a separate, approved step between them:

1. **Phase 1** - create the parameter group (`apply_method = pending-reboot`).
2. **Attach** the group to the instance, in the stack that owns the instance.
3. **Reboot** - `scripts/reboot.sh`. One time per instance.
4. **Phase 2** - everything else, only once `wal_level = logical`.

`reboot.sh` is a report by default. It reboots only with `--confirm`, and only if **every**
instance is `available`, is attached to the **expected** parameter group, and shows
`pending-reboot` (so a reboot that would change nothing is refused). `--approved-by` is required and
printed in an audit line. Its decision logic is tested with a stubbed `aws` command; the real AWS
query path has not been exercised.

**Who approves / performs it** is organisational - suggested: the team that owns the database
approves (they feel the outage), the platform team runs it, prod goes through change control in a
maintenance window. A protected GitHub environment gives a reviewable approval:

```yaml
# in a PRIVATE repo, on a self-hosted runner
on: workflow_dispatch
jobs:
  reboot:
    runs-on: [self-hosted]
    environment: prod        # required reviewers configured on this environment
    steps:
      - uses: actions/checkout@v4
      - run: scripts/reboot.sh --identifier "$DB" --region "$REGION" --parameter-group "$PG" --approved-by "$GITHUB_ACTOR / $TICKET" --confirm --wait
```

## 5 and 6. Still open

**5. Inputs.** Provided today: `name`, `environment`, `host`, `database`, `admin_username`,
`publication_tables` (required); everything else has a default. Missing versus the ticket: the
**RDS instance identifier** and **parameter group name** are not module inputs, and the WAL cap uses
a storage figure typed in rather than read from the instance.

**6. Location.** Undecided. The code is generic and can be copied into either a shared infra repo
or a dedicated modules repo. Note the `postgresql` provider cannot be configured with `for_each`,
so wherever it lives it needs one root (and one state) per source database.
