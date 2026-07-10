# Lab 06 — Secrets, database migrations, JAR files and third-party modules

**Day 4 · morning session.** Four things every real Ignition deployment carries
that the pipeline doesn't handle yet: secrets, the database schema, third-party
modules and JAR files. The Wilms and Proferro production repos are the working
references throughout.

**Duration:** ~3 hours

* 60 min teaching ([`slides/teaching.html`](../slides/teaching.html))
* 45–60 min we-do (demos below, woven into the teaching)
* 60 min you-do ([`slides/assignment.html`](../slides/assignment.html) mirrors this file)
* Debrief

<!-- TODO(infra): the lab repo scaffolding (compose stack, secrets/ dir,
     db-migration/ dir, scripts/migrate.sh, spare .modl files, deploy.yml
     skeleton) is not built yet. The exercises below define the target. -->

## Goal

You should leave this lab able to:

- Sort configuration into **public / per-environment / secret**, and say where each kind lives
- Explain why a secret that has ever been pushed is **burned** — the fix is *rotate*, not *delete*
- Climb the secrets ladder: `.env` + Compose interpolation → **file-based secrets** (`/run/secrets/`) → Ignition 8.3 secret providers (embedded vs **referenced**)
- Wire the whole path: **GitHub secret → secret file written by the deploy workflow → file-type secret provider → referenced secret in gateway config** (the Wilms production pattern)
- Name the alternative: committed **ciphertexts with shared encryption keys**, managed with the 8.3 secrets-management key CLI tool (`ignition-secrets-tool.sh`)
- Explain why `db-init/` is bootstrap, not deployment
- Write a schema change as a **golang-migrate up/down pair** (`0002_name.up.sql` / `.down.sql`, like the Proferro repo), apply it with `migrate up`, and read the `schema_migrations` ledger
- Wire a migrate step into `deploy.yml` **before** the ship step, and say why the order matters
- Deploy a **third-party module**: committed `.modl`, external-modules folder flag, headless license/cert acceptance in `modules.json`
- Say where the two kinds of **JAR** live: JDBC drivers as 8.3 config resources (inside the config tree), library JARs on the gateway classpath

## Pre-flight

```bash
cp .env.example .env
scripts/setup.sh          # idempotent — safe if the stack is already up
scripts/validate.sh       # green before you start
```

Parts 1C and 2B need your fork with Actions enabled (same setup as Lab 04): the
pipeline is what writes the secret files and runs the migrations.

---

## We-do (instructor demos)

### Demo 1 — a leak is forever

1. Commit a fake API key on a branch, push, then "remove" it in a follow-up commit.
2. `git log -p` / GitHub UI: the key is still perfectly readable in history.
3. The real-world response: **rotate the credential**, then (optionally) scrub history — and why scrubbing alone is never enough on a shared remote.

### Demo 2 — the secrets ladder, on the Wilms repo

1. The `.env` → Compose interpolation rung and where it leaks: `docker inspect`, `docker compose config`, process env.
2. The Wilms setup live: `secrets/` with committed dummy values for local dev, the `WilmsSecrets` file-type provider, a DB connection whose password is `{"type": "Referenced", "data": {"providerName": "WilmsSecrets", "secretName": "MSSQL_PASSWORD"}}`, and the `${ENV:NAME}` placeholders in the core collection that the boot script renders to files (umask + chmod **before** the value lands).
3. The infra handoff: `docs/infra-env-vars-rabbitmq-seq.md` — the table of env vars the infra team fills per environment.

### Demo 3 — migrations, live on the Proferro repo

1. `db-init/` recap: rename the volume → SQL runs; existing volume → it doesn't. Bootstrap, not deployment.
2. The `db-migration/migrate/` folder: 4-digit paired files (`0001_….up.sql`/`.down.sql`), `docs/MIGRATIONS.md` rules ("always pairs", "never edit deployed migrations"), `migrate.sh` running golang-migrate in Docker, the `schema_migrations` table.
3. The pipeline steps in `.azure/pipelines.yml` — and the two flaws worth spotting together: migrations run **after** the scan, with `continueOnError: true`. What can go wrong?

### Demo 4 — modules and JARs, in both repos

1. Proferro `third-party-modules/it|ot/` and the copy step to the gateway host; Wilms `modules/ignition/` as a COPY layer.
2. Headless acceptance: `ACCEPT_MODULE_LICENSES` / `ACCEPT_MODULE_CERTS` env vars, and `modules.json` entries with `certFingerprint` + `licenseAgreementHash`.
3. The JDBC driver JAR living **inside** the 8.3 config tree (`database-driver/PostgreSQL/postgresql-42.7.2.jar` next to its `config.json`), vs Wilms' library JARs (`modules/jar/` → `lib/core/gateway/`) with pinned dependencies and a README recording where each JAR came from.

## You do (breakout rooms)

Follows [`slides/assignment.html`](../slides/assignment.html) 1:1.

### Warm-up 1 — secret triage
Grep your clone for candidate secrets; sort into public / per-environment / secret in `NOTES.local.md`; check `.gitignore` covers `.env` and `secrets/`; run the secret scan in `scripts/validate.sh` for a zero-findings baseline. <!-- TODO(infra): gitleaks step in validate.sh -->

### Warm-up 2 — leak & rotate drill
Repeat Demo 1 yourself on a scratch branch; convince yourself the "deleted" secret is still in history; write the two-line incident response (rotate → then scrub) in `NOTES.local.md`; delete the branch, never push it.

### Part 1 — move one credential up the secrets ladder (±20 min)
- **1A.** Postgres password: compose `environment:` → a secret file mounted at `/run/secrets/postgres_password` (`POSTGRES_PASSWORD_FILE`). Keep the same value — Postgres only sets it on first volume init.
- **1B.** Create a **file-type secret provider** on the local gateway; re-point the DB connection at the **referenced** secret; grep the exported config to prove no value leaked.
- **1C.** Add `POSTGRES_PASSWORD` as a GitHub environment secret and add the **Materialize secret files** step to `deploy.yml` (umask 177 + `printf`, before `compose up`).
- **Gate:** `scripts/validate.sh` green, secret scan zero findings, and you can narrate: GitHub secret → file → provider → reference.

### Part 2 — ship a schema change as a migration (±20 min)
- **2A.** Write `db-migration/migrate/0002_add_downtime_log.up.sql` **and** `.down.sql`; apply with `scripts/migrate.sh up`; read `schema_migrations` (version 2, not dirty); re-run to see idempotency. Note: golang-migrate will NOT stop you editing an applied migration — that discipline is a written rule (Proferro `docs/MIGRATIONS.md`), not a tool feature.
- **2B.** Add the migrate step to `deploy.yml` **before** the ship step (and not `continueOnError`); PR with the migration **and** the screen that reads the new table together; watch the run migrate dev before shipping; prove it in dev's `schema_migrations`.
- **Gate:** a green deploy run whose log shows migrate → ship → scan → verify, and dev's ledger at version 2.

### Part 3 — deploy a module and a JDBC driver (±20 min)
- **3A.** Enable a spare `.modl` from `third-party-modules/` in `services/modules.json` with `certFingerprint` + `licenseAgreementHash` (values in this file); ship through the pipeline; verify Config → Modules shows it **Running** with no hands on the gateway. Negative test: remove the acceptance hash, redeploy, observe, restore. <!-- TODO(infra): pick the spare module and record its fingerprint + hash here -->
- **3B.** `find services/config -name "*.jar"` — find the JDBC driver inside the config tree, read its `resource.json`, and write down how it reaches the gateway (the ordinary config ship step). Contrast with Wilms' classpath JARs.
- **Gate:** module Running on dev, hands-free.

### Stretch (optional)
- **S1.** Committed ciphertexts done safely: `ignition-secrets-tool.sh` root key + KEK under `data/config/ignition/keys/`; share the keys between two gateways; check a ciphertext created on one decrypts on the other. What is "the secret" now, and who owns it?
- **S2.** Expand-contract rename: `0003` add + backfill, screen switch, `0004` drop.
- **S3.** Add a `gitleaks` job to `ci.yml` (`fetch-depth: 0` — the scanner must see history); test with a fake-key PR.

## Debrief

- One surprise, one question, per room.
- Which secrets approach fits your plant: references + files, or ciphertexts + shared keys? What does each make easy, and what does each make dangerous?
- The Proferro ordering question: migrations after the scan, `continueOnError: true` — what incident does that setup eventually produce?
