# OVH backend state

OVH cluster and bastion roots have independent state. Lifecycle recipes default
to `BACKEND=s3`; `BACKEND=local` is an explicit, project/stack-isolated mode,
not an outage fallback. A backend change always requires explicit migration.

## Configure S3

Create the bucket and dedicated S3 user outside these roots. Enable bucket
versioning and encryption, but not Object Lock: OpenTofu must update both state
and `.tflock` objects. Copy the safe template and replace its placeholders:

```bash
cp env/OVH/example/backend.s3.tfbackend \
  env/OVH/<project>/backend.s3.tfbackend
```

Keep S3 credentials only in ignored `env/OVH/<project>/.env` as
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Backend files contain no
credentials. One shared file serves both stacks: `scripts/ovh-backend.sh`
injects the distinct `key`/`workspace_key_prefix` per stack (clusters vs
bastion) at `init`, preventing cluster/bastion and workspace collisions.
Recipes that need cloud or backend access source the project `.env`, then the
selected `OPENRC` or project `openrc.sh`; values assigned by those files
override same-named ambient variables, while ambient variables remain usable
when the files are absent.

## Initialize and inspect

Initialization is deliberate and separate from lifecycle commands:

```bash
PROJECT=<project> BACKEND=s3 just ovh::backend-init
PROJECT=<project> BACKEND=s3 just ovh::bastion-backend-init
PROJECT=<project> BACKEND=s3 just ovh::backend-status
PROJECT=<project> BACKEND=s3 just ovh::bastion-backend-status
```

Each status command checks only the selected stack's local initialization
metadata, requested backend mode, and current config fingerprint. It does not
contact S3, enumerate workspaces, or source credential files; no ambient cloud
credentials are needed for status.

Use `BACKEND=local` only when intentionally creating isolated state under
`.local/backend-state/ovh/<project>/<stack>/`. Plan/deploy/destroy/bootstrap and
bastion convergence refuse missing initialization, changed backend config, and
backend-mode mismatches. They never fall back to local state.

Validation is offline-safe: `just ovh::validate` and
`just ovh::bastion-validate` use `tofu init -backend=false`, need no S3
credentials, and do not initialize or migrate state.

## Migrate

Migration creates per-workspace mode-`0600` state snapshots plus backend
metadata under ignored `.local/backend-backups/`, then runs interactive
`tofu init -migrate-state`. It never supplies `-force-copy` or answers prompts.
Review the destination warning and stop rather than overwrite unexpected state.

Current roots with their historical in-directory local state use:

```bash
PROJECT=<project> just ovh::backend-migrate legacy-local s3
PROJECT=<project> just ovh::bastion-backend-migrate legacy-local s3
```

For an initialized backend switch, name both ends explicitly:

```bash
PROJECT=<project> just ovh::backend-migrate s3 local
PROJECT=<project> just ovh::backend-migrate local s3
```

An S3 config/key change is also a migration: keep the initialized source,
edit the project backend file, then run `backend-migrate s3 s3`. After any
migration, run `backend-status` and plan every workspace before retaining the
new mode. Keep the backup and S3 object versions until verification completes.
Recovery is an explicit reverse migration. A migration first writes
`infra-backend-migration` beside the backend metadata and removes it only after
OpenTofu migration and the final marker both succeed. While that journal exists,
all backend commands refuse to run: do not delete it or retry blindly. Compare
its `from`/`to` values, the matching backup, both backend workspace lists, and
state serials to identify the authoritative backend before an operator-reviewed
recovery.
