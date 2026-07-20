# Troubleshooting

Quick fixes for the things that bite people during Labs A and B. Work top to bottom; most issues
are one of the first three.

## The stack won't start / `scripts/setup.sh` fails

- **Docker isn't running or isn't Compose v2.** `docker compose version` must work (note the space —
  not `docker-compose`). Start Docker Desktop and re-run `scripts/setup.sh` (it's idempotent).
- **Not enough RAM.** Three gateways at 1 GB each + TimescaleDB + the runner need **≥ 8 GB free**.
  If gateways crash or never reach RUNNING, raise Docker's memory or bump the per-gateway limit in
  [`docker-compose.yaml`](../docker-compose.yaml).
- **Port already in use.** 8088/8089/8090 (gateways) or 5432 (TimescaleDB) taken by something else.
  Stop the other process or change the host port mappings in `docker-compose.yaml`.

## A gateway never reaches RUNNING

- Give it time — a cold JVM start can take 60–120 s per gateway. `setup.sh` polls up to ~240 s each.
- Check logs (note: use `docker logs`, the container name — *not* `docker compose logs`, which wants
  the service name):
  ```bash
  docker logs --tail 200 lab06-gateway-local-development     # or -test / -production
  ```
- **Trial expired.** Each gateway runs in 2-hour trial mode. After it lapses the gateway stops
  serving. Reset via *Gateway → Config → Licensing → Reset Trial* (unlimited, legal for test).

## `git status` shows lots of `resource.json` changes

Ignition rewrites the `resource.json` manifests on every interaction, usually touching nothing
but volatile metadata (modification timestamp, actor, signature). That churn is **meant to be
visible** — real edits must show up in git — and it's undone, not hidden:

```bash
scripts/clean-ignition-resource-churn.sh          # dry run: lists volatile-only files
scripts/clean-ignition-resource-churn.sh --apply  # restores them from HEAD
```

Files with real content changes (and anything staged) are never touched by the script.
`git diff` already hides the volatile metadata: `scripts/setup.sh` wires a textconv driver
(`scripts/git-diff/normalize-ignition-resource-json.py`) via `.gitattributes`. If diffs still
show timestamp/signature noise, re-run `scripts/setup.sh`.

The one exception is the machine-local `local-system-properties/config.json` (system UID, trial
state — it belongs to this specific box). The hooks installed by `scripts/setup.sh` keep it
`skip-worktree` so it never dirties the tree. To intentionally change that seed file and commit it:
```bash
git update-index --no-skip-worktree <path>
# edit, commit, push — the next pull re-applies skip-worktree
```

## The self-hosted runner is offline / jobs queue forever

- Container up? `docker compose ps github-runner` and `docker logs lab06-runner` (look for
  *"Listening for Jobs"*).
- **Restart loop with a *401* in the logs?** The runner authenticates with the `repo`-scope PAT in
  `RUNNER_GITHUB_PAT` (`.env`) — a 401 means it's still the placeholder or an invalid/expired token.
  Fix it, then `docker compose up -d --force-recreate github-runner`.
- `RUNNER_REPO_URL` in `.env` must point at **your fork**, not the upstream.
- `RUNNER_GITHUB_PAT` in `.env` must be a real GitHub Personal Access Token with `repo` scope
  (reuse the one you created in Lab 04, or make one at github.com/settings/tokens → classic → tick `repo`).
- In your fork: *Settings → Actions → Runners* should list it online with the `self-hosted, lab06`
  labels.
- Don't add `EPHEMERAL` to the runner's environment in `docker-compose.yaml` — the image treats
  **any** non-empty value (even `"false"`) as "enable ephemeral mode", which deregisters the runner
  after every job.

## The deploy 403s on the scan step

The `IGNITION_API_KEY` for that environment is missing, wrong, or under-scoped. Generate the key
**on the target gateway's own UI** (*Config → Security → API Keys*), scope it to **Project Scan +
Config Scan**, and set it as the `IGNITION_API_KEY` secret on the matching GitHub environment
(`lab-gateway-test` / `lab-gateway-production`). Keys are **per-gateway** — a test key won't authenticate
against production.

## The scan step 401s on a fresh gateway

The scan API only accepts tokens the gateway has **loaded** — and a deploy can't scan in its own
token, because the scan call already needs it (chicken-and-egg). On a gateway that never loaded the
committed `cicd` token, the first deploy copies everything to disk (token included) but the scan
401s: it *looks* like "the API key deployed but nothing else did". **The deploy workflows now
self-heal this:** on a 401 (token never loaded) or 403 (first-boot commissioning reset the
permissions), the scan step restarts the gateway container once — the Ship step already copied the
token and `security-properties` onto its disk, and the gateway loads them at boot — waits for
RUNNING, and retries the scans. So the first deploy to a fresh gateway goes green on its own, even
if the stack was started with plain `docker compose up`; every later deploy hot-scans, no restart.
Where `scripts/setup.sh` still matters is **manual** scans (`scripts/scan.sh`) *before* the first
deploy: it pre-seeds the token into `gateways/test/config` and `gateways/production/config` before first
boot, and self-heals a probe that still 401s by seeding the token and restarting that gateway. If
manual scans fail, re-run `scripts/setup.sh`. Don't hand-generate a replacement token in the
gateway UI without committing it — the next deploy wipes uncommitted tokens and you're back to 401.

## Locked out of test/production after a deploy (admin password rejected)

Historically this happened when a deploy shipped the repo's copy of
`config/resources/core/ignition/user-source/` — its `users.json` carries the **local** gateway's
admin password hash, so it overwrote the target's own admin user. The current workflows spare the
gateway-owned internal identity **by name** — `user-source/default/`, `user-source/opcua-module/`,
and `identity-provider/default/` — in the wipe, and `.deployignore` keeps those dirs out of the
payload, so this shouldn't happen anymore. (Other user sources and identity providers — database,
AD, SAML/OIDC — hold no password data and deploy normally, as does `security-properties`.) If you
still hit it (e.g. an older working tree):

- **Full reset:** `scripts/teardown.sh --volumes`, then `scripts/setup.sh`. Nukes all gateway state.
- **Targeted:** delete `gateways/<gw>/config/resources/core/ignition/user-source`, then re-run
  `scripts/setup.sh` — it notices the missing identity, recreates that gateway's data volume so
  commissioning runs again, and the admin user comes back from the `GATEWAY_ADMIN_*` values in
  `.env`. (Deleting the files alone is not enough: the old volume still says "already
  commissioned", so the gateway would boot with no identity at all.)

## Login page says `Identity provider not found: default` (HTTP 500)

The gateway is running but has no internal identity on disk. Classic cause: a **fresh clone next
to an old stack** — you deleted or re-cloned the repo folder without `scripts/teardown.sh
--volumes` first. Docker Compose reuses data volumes by project (folder) name, so the gateway
boots against the old volume, believes it is already commissioned, and never re-creates the
`default` user source / identity provider that used to live in the (now gone) config tree.

**Fix:** re-run `scripts/setup.sh`. It detects the desync (volume exists, identity missing) and
recreates the affected gateway's container + volume so commissioning runs again. Rule of thumb:
always `scripts/teardown.sh --volumes` before deleting or re-cloning the folder.

## I merged my PR but nothing deployed (GitHub Flow)

This lab uses GitHub Flow — the branch decides the gateway:

- **Did your PR actually merge into `main`?** `deploy.yml` fires on pushes to `main`, and merging a PR is what produces that push. If the PR is still open (or merged into some other branch), nothing ships to test.
- **Did the change touch a deploy path?** Confirm it hit `projects/**` or `services/config/**`; a docs-only push to `main` is filtered out by the `paths:` filter.
- **Is Actions enabled on your fork?** No enabled workflows means no runs at all. Check *Settings → Actions* on your fork.
- **Production doesn't update on a `main` merge — that's intentional.** Production is reached by **tagging**: `git tag vX.Y.Z && git push origin vX.Y.Z` fires `release.yml`.

## The deploy ran but my change isn't visible

- Are you looking at the right gateway? `local` = :8088, `test` = :8089, `production` = :8090.
- Did the scan return HTTP 200? `scripts/scan.sh` pretty-prints the response with a
  `lastScanTimestamp`. Files on disk without a successful scan = gateway hasn't reloaded.
- Module enable/disable (`services/modules.json`) needs a **restart**, not a scan:
  `docker compose restart gateway-test`.

## Validate before you push

```bash
scripts/validate.sh    # JSON parse + .deployignore syntax + actionlint — mirrors CI
```

Still stuck? The instructor answer key ([lab-key.md](../instructor-notes/lab-key.md)) has a
deeper failure-mode walkthrough.
