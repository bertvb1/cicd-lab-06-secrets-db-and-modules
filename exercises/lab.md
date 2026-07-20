# Lab 06 — Secrets, database migrations, JAR files and third-party modules

**Day 4 · morning session.** Four things every real Ignition deployment carries
that the pipeline doesn't handle yet: secrets, the database schema, third-party
modules and JAR files. Two real production Ignition repos we maintain (one
file-based, one image-based; shown on screen by the instructor) are the working
references throughout.

**Duration:** ~3 hours

* 60 min teaching ([`slides/teaching.html`](../slides/teaching.html))
* 45–60 min we-do (demos below, woven into the teaching)
* 60 min you-do ([`slides/assignment.html`](../slides/assignment.html) mirrors this file)
* Debrief

<!-- Infra status: the scaffolding (compose stack, secrets/ dir, db-migration/
     + scripts/migrate.sh, spare .modl, ci.yml secret scan, deploy.yml skeleton
     with the 1C/2B insertion points marked) is built, and the seeded broken
     state is verified live on 8.3.6 (local Valid, test Faulted on "Unable to
     decrypt ciphertext"; migrate.sh up/down/version green). Still open before
     the course: the fork-side pipeline runs — see instructor-notes/lab-key.md
     §A2. -->

## Goal

You should leave this lab able to:

- Sort configuration into **public / per-environment / secret**, and say where each kind lives
- Explain why a secret that has ever been pushed is **burned** — the fix is *rotate*, not *delete*
- Climb the secrets ladder: `.env` + Compose interpolation → **file-based secrets** (`/run/secrets/`) → Ignition 8.3 secret providers (embedded vs **referenced**)
- Wire the whole path: **GitHub secret → secret file written by the deploy workflow → file-type secret provider → referenced secret in gateway config** (the production pattern)
- Name the alternative: committed **ciphertexts with shared encryption keys**, managed with the 8.3 secrets-management key CLI tool (`ignition-secrets-tool.sh`)
- Explain why `db-init/` is bootstrap, not deployment
- Write a schema change as a **golang-migrate up/down pair** (`0002_name.up.sql` / `.down.sql`, like our file-based production repo), apply it with `migrate up`, and read the `schema_migrations` ledger
- Wire a migrate step into `deploy.yml` **before** the ship step, and say why the order matters
- Deploy **third-party modules**: committed `.modl` files, external-modules folder flag, headless license/cert acceptance in `modules.json`
- Say where the two kinds of **JAR** live: JDBC drivers as 8.3 config resources (inside the config tree), library JARs on the gateway classpath

## Pre-flight

```bash
cp .env.example .env
scripts/setup.sh          # idempotent — safe if the stack is already up
scripts/validate.sh       # green before you start
```

The warm-up, Parts 1C–1D and 2B need your fork with Actions enabled (same setup
as Lab 04): the pipeline is what deploys, writes the secret files and runs the
migrations.

---

## We-do (instructor demos)

### Demo 1 — a leak is forever

1. Commit a fake API key on a branch, push, then "remove" it in a follow-up commit.
2. `git log -p` / GitHub UI: the key is still perfectly readable in history.
3. The real-world response: **rotate the credential**, then (optionally) scrub history — and why scrubbing alone is never enough on a shared remote.

### Demo 2 — the secrets ladder, on the image-based production repo (on screen)

1. The `.env` → Compose interpolation rung and where it leaks: `docker inspect`, `docker compose config`, process env.
2. The production setup live: `secrets/` with committed dummy values for local test, a file-type secret provider, a DB connection whose password is `{"type": "Referenced", "data": {"providerName": "PlantSecrets", "secretName": "MSSQL_PASSWORD"}}`, and the `${ENV:NAME}` placeholders in the core collection that the boot script renders to files (umask + chmod **before** the value lands).
3. The infra handoff doc: the table of env vars the infra team fills per environment.

### Demo 3 — migrations, live on the file-based production repo (on screen)

1. `db-init/` recap: rename the volume → SQL runs; existing volume → it doesn't. Bootstrap, not deployment.
2. The `db-migration/migrate/` folder: 4-digit paired files (`0001_….up.sql`/`.down.sql`), `docs/MIGRATIONS.md` rules ("always pairs", "never edit deployed migrations"), `migrate.sh` running golang-migrate in Docker, the `schema_migrations` table.
3. The pipeline steps — and the two flaws worth spotting together: migrations run **after** the scan, with `continueOnError: true`. What can go wrong?

### Demo 4 — modules and JARs, in both repos

1. The file-based repo's `third-party-modules/it|ot/` and the copy step to the gateway host; the image-based repo's `modules/ignition/` as a COPY layer.
2. Headless acceptance: `ACCEPT_MODULE_LICENSES` / `ACCEPT_MODULE_CERTS` env vars, and the `modules.json` `certFingerprint` + `licenseAgreementHash` the gateway *derives* on first boot (you commit what it wrote — you never type them).
3. The JDBC driver JAR living **inside** the 8.3 config tree (`database-driver/PostgreSQL/postgresql-42.7.2.jar` next to its `config.json`), vs library JARs (`modules/jar/` → `lib/core/gateway/`) with pinned dependencies and a README recording where each JAR came from.

## You do (breakout rooms)

Follows [`slides/assignment.html`](../slides/assignment.html) 1:1.

### Warm-up (together) — deploy to develop and production, and check the db-connections
Pre-flight first (`validate.sh` green). Then create the two **deploy
environments** on your fork — *Settings → Environments* → `lab-gateway-test`
and `lab-gateway-production` — each with a secret named `IGNITION_API_KEY`
holding that gateway's own key from your `.env` (`setup.sh` generated a
unique `IGNITION_API_KEY_TEST` / `_PRODUCTION` per gateway — nothing
key-related lives in the repo, and a test key won't authenticate against
production). `deploy.yml` picks its environment from the deploy target, so
without them nothing deploys. From the CLI instead of the UI:

```bash
gh api -X PUT repos/<you>/cicd-lab-06-secrets-db-and-modules/environments/lab-gateway-test
gh api -X PUT repos/<you>/cicd-lab-06-secrets-db-and-modules/environments/lab-gateway-production
gh secret set IGNITION_API_KEY --env lab-gateway-test  --body "$(grep '^IGNITION_API_KEY_TEST=' .env | cut -d= -f2-)"
gh secret set IGNITION_API_KEY --env lab-gateway-production --body "$(grep '^IGNITION_API_KEY_PRODUCTION=' .env | cut -d= -f2-)"
```

Now trigger `deploy.yml` for develop and
for production from the Actions tab and watch both runs go green. Now open the develop
gateway, Config → Databases → Connections: both connections (`TimescaleDB` and
`TimescaleDB_Reports`) are **Faulted**; production shows the same. Write the diagnosis
question in `NOTES.local.md`: the pipeline is green and the gateway is broken —
what can a config-only deploy never carry? (Answer lands in Part 1: the password
values and the per-environment database target.)
<!-- Seeded state: TimescaleDB_Reports exists only in core (username
     `reporting`, connectURL → ignition_local_development); TimescaleDB has the local-development/test/production
     overrides. Both passwords are Embedded ciphertexts under CUSTOM
     secrets-management keys that are committed for the local gateway
     (services/config/ignition/keys/ + IGNITION_ROOT_KEY_PASSWORD in compose)
     and excluded from the deploy payload — so local decrypts them and
     test/production fault with "Unable to decrypt ciphertext", by design. See
     instructor-notes/lab-key.md §A1 for the verified mechanics and the
     mint tooling. -->

### Part 1 — hook up a secret for the db-connection (±30 min)
Two db-connections, same database server, different users: `TimescaleDB` logs in
as `ignition`, `TimescaleDB_Reports` as the read-only `reporting` user.
- **1A.** Both passwords become secret files: compose `environment:` → files
  mounted at `/run/secrets/postgres_password` and `/run/secrets/reporting_password`
  (`POSTGRES_PASSWORD_FILE` on the DB service; both secrets also attached to the
  gateway service). Keep the same values — Postgres only sets them on first
  volume init.
- **1B.** Create a **file-type secret provider** (`LabSecrets`) on the local
  gateway with secrets `POSTGRES_PASSWORD` and `REPORTING_PASSWORD`; re-point
  **both** connections at their **referenced** secret (in every deployment
  mode that overrides the password field). Then check `git status`: the UI
  writes the provider into the **active mode's collection**
  (`resources/local-development/ignition/secret-provider/`), and `local-development` never deploys —
  develop would fault on a missing provider while local stays green. Move it
  to core and rescan:

  ```bash
  mv services/config/resources/{local-development,core}/ignition/secret-provider
  ./scripts/scan.sh config    # still Valid, now from core
  ```

  Finally, grep the exported config to prove no value leaked.
- **1C.** Build the fix for develop, in two halves: add the **test
  deployment-mode override** for `TimescaleDB_Reports`
  (`…resources/test/ignition/database-connection/TimescaleDB_Reports/config.json`,
  connectURL → `ignition_test`) **and its `production` twin** (connectURL →
  `ignition_production` — production inherits the same core flaw; copy the pattern from
  `TimescaleDB`, which has all three modes), and add
  `POSTGRES_PASSWORD` + `REPORTING_PASSWORD` as secrets on **both** the
  `lab-gateway-test` and `lab-gateway-production` environments plus the
  **Materialize secret files** step in `deploy.yml`
  (umask 177 + `printf`, before `compose up`). Nothing is deployed yet.
- **1D.** The full deploy moment, every station separately: **branch**
  (`feature/fix-test-db-connections`) → **commit & push** (no secret values in
  the diff) → **open the PR** → **watch the PR validate** (`ci.yml` green) →
  **merge** → **watch the pipeline deploy** (materialize secrets → up → scan →
  verify) → **verify develop** (both connections Valid, `TimescaleDB_Reports`
  on `ignition_test`) → **promote to production** (Actions → `deploy.yml` → Run
  workflow → `target: production` — same commit, same pipeline, different
  environment) → **verify production** (both Valid, `TimescaleDB_Reports` on
  `ignition_production`).
- **Gate:** both connections Valid on develop AND production, fixed by the pipeline
  and not by hand, and you can narrate: GitHub secret → file → provider →
  reference.

### Part 2 — ship a schema change as a migration (±20 min)
- **2A.** Write `db-migration/migrate/0002_add_downtime_log.up.sql` **and** `.down.sql`; apply with `scripts/migrate.sh up`; read `schema_migrations` (version 2, not dirty); re-run to see idempotency. Note: golang-migrate will NOT stop you editing an applied migration — that discipline is a written rule (the production repo's `docs/MIGRATIONS.md`), not a tool feature.
- **2B.** Add the migrate step to `deploy.yml` **before** the ship step (and
  not `continueOnError`), deriving the database from the deploy target —
  `$DEPLOY_TARGET` is already in the job's env, and a `target: production`
  promotion must migrate `ignition_production`, not test:

  ```yaml
  - name: Migrate database
    run: |
      case "$DEPLOY_TARGET" in
        production) db=ignition_production ;;
        *)    db=ignition_test ;;
      esac
      ./scripts/migrate.sh up --database "$db"
  ```

  PR with the migration **and** the screen that reads the new table together; watch the run migrate test before shipping; prove it in test's `schema_migrations`.
- **Gate:** a green deploy run whose log shows migrate → ship → scan → verify, and test's ledger at version 2 (a later production promotion migrates `ignition_production` the same way).

### Part 3 — deploy three third-party modules (±10 min)
- Install the three spare `.modl` files by adding **minimal** `services/modules.json` entries, let the gateway derive the acceptance fields, commit them, ship them through the pipeline, and verify they come up **Running** with no hands on the gateway.

  The spare modules are **Embr Periscope**, **Embr Charts** and the **TimescaleDB Historian**. Their `.modl` files already sit in `third-party-modules/`, and all three module ids are already listed in the compose `GATEWAY_MODULES_ENABLED`, `ACCEPT_MODULE_LICENSES`, and `ACCEPT_MODULE_CERTS` env vars — but they ship **without a `modules.json` entry**, so the gateway does not load them. Nothing runs until you add the entries.

  **Step 1 — add the lines you actually know.** You do *not* know the fingerprints or the license hashes, and you shouldn't guess. The module ids are hard to discover, so they are given here. Add only:

  ```json
  "com.mussonindustrial.embr.periscope": {
    "filename": "/third-party-modules/Embr-Periscope-Ignition83-0.12.0.modl",
    "onStartup": "enabled"
  },
  "com.mussonindustrial.embr.charts": {
    "filename": "/third-party-modules/Embr-Charts-Ignition83-4.0.1.modl",
    "onStartup": "enabled"
  },
  "com.mustry.historian.timescaledb": {
    "filename": "/third-party-modules/TimescaleDB-Historian.modl",
    "onStartup": "enabled"
  }
  ```

  **Step 2 — boot once and let the gateway fill in the rest.** Restart the local gateway (`docker restart lab06-gateway-local-development`, or re-run `scripts/setup.sh`). Because acceptance is already in the env vars, the gateway installs the modules headlessly and **rewrites `modules.json`**, appending to each entry the two fields it computed:

  ```json
    "certFingerprint": "e5a3cf3f06627c175b68b0122ac8f2c3f9c992e2",
    "licenseAgreementHash": 101444854
  ```

  `git diff services/modules.json` shows exactly what it added. **Commit those lines.** They are the whole point: with acceptance stored as data, a *fresh* gateway (an image-based deploy, a rebuilt container) installs the modules without a human ever clicking an install dialog — and without needing the env vars at all.

  **Step 3 — verify they are actually Running (two ways, no UI needed):**

  ```bash
  # 1) a module's web resources are served only when it is Running:
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8088/res/embr-periscope/   # -> 200
  # 2) the gateway logged them starting up:
  docker logs lab06-gateway-local-development 2>&1 | grep "Starting up module 'com.mussonindustrial"
  ```

  A `200` (not `302`/`404`) plus a `Starting up module` line = installed and Running. In the UI it is *Config → Modules*: all three listed, all Running.

  **Step 4 — ship them.** PR → merge → deploy run. Because the module manifest changed, the deploy **restarts** the gateway: modules only load at boot, unlike projects and config, which reload hot.

  **Negative test (what un-accepted looks like), on one module:** in a scratch checkout, delete its two derived lines **and** drop `com.mussonindustrial.embr.periscope` from `ACCEPT_MODULE_LICENSES` / `ACCEPT_MODULE_CERTS`, wipe the local volume, and boot. With the module enabled but unaccepted the gateway parks at the commissioning screen — `curl http://localhost:8088/StatusPing` returns `{"state":"RUNNING","details":"COMMISSIONING"}` and `/res/embr-periscope/` redirects (`302`). Put both back to recover.
- **Gate:** all three modules Running on test, hands-free — `/res/embr-periscope/` returns `200`.

### Stretch (optional)
- **S1.** The internal secret provider, and where it breaks: create an **internal secret provider** on the local gateway, store `REPORTING_PASSWORD` in it (the gateway encrypts it and keeps the ciphertext in its own config) and point `TimescaleDB_Reports` at it. Locally it stays Valid; ship it and develop faults — the ciphertext only decrypts on the gateway that created it. Explore `ignition-secrets-tool.sh` (shared root key + KEK under `data/config/ignition/keys/`) as the escape hatch, then revert to the referenced secret. What is "the secret" now, and who owns it?
- **S2.** Expand-contract rename: `0003` add + backfill, screen switch, `0004` drop.
- **S3.** Add a `gitleaks` job to `ci.yml` (`fetch-depth: 0` — the scanner must see history); test with a fake-key PR.

## Debrief

- One surprise, one question, per room.
- Which secrets approach fits your plant: references + files, or ciphertexts + shared keys? What does each make easy, and what does each make dangerous?
- The production ordering question from Demo 3: migrations after the scan, `continueOnError: true` — what incident does that setup eventually produce?
