# Lab 06 — Secrets, database migrations, modules & JARs

Day 4 (morning) of the [CI/CD for Ignition Masterclass](https://github.com/mustry-academy/cicd-masterclass).

> Four things every real Ignition deployment carries that the pipeline so far doesn't handle: **secrets**, the **database schema**, **third-party modules** and **JAR files**. You move the database passwords out of Git and onto the secrets ladder (env var → file-based secret → Ignition 8.3 **referenced secret**), ship a schema change as a **golang-migrate up/down pair** the pipeline applies *before* the screens that need it, and deploy a `.modl` with headless license acceptance — so a fresh gateway boots complete with no hands on it.

This lab reuses Lab 04's file-based deploy stack (three gateways, bundled self-hosted runner, `docker cp` + hot scan). What's new is everything the config files *can't* say: password values, schema state, module binaries.

## Prerequisites

- A fork of this repo, **with Actions enabled** — the warm-up, Parts 1C–1D and 2B are pipeline work (same setup as Lab 04)
- A GitHub Personal Access Token with `repo` scope — the bundled runner uses it to auto-register against your fork. **Reuse the one you made in Lab 04** (or create one at [github.com/settings/tokens](https://github.com/settings/tokens) → classic → tick `repo`) and put it in `.env` as `RUNNER_GITHUB_PAT`. It never leaves `.env`.
- The [GitHub CLI](https://cli.github.com/) (`gh`), authenticated (`gh auth status`) — used to fork and clone the repo
- **≥ 8 GB free RAM for Docker** — three Ignition gateways each cap at 1 GB, plus TimescaleDB, the runner, and the usual Docker Desktop overhead
- _Background:_ [Lab 04](https://github.com/mustry-academy/cicd-lab-04-ignition-file-based-deploy) — this lab reuses its stack and deploy mechanics; the config-scope overlays (`local-development`/`test`/`production`) it shipped silently become load-bearing here


> **WSL2 (Windows): keep the clone in your Linux home (`~/…`), never `/mnt/c/…`.**
> On the Windows filesystem your Windows user, your WSL user and the gateway's
> container user are three different identities, so file ownership breaks in ways
> `chown` cannot fix and you end up reaching for `sudo` (which makes it worse).
> `scripts/setup.sh` refuses to run from there, and never needs `sudo`.
> See [`docs/wsl-setup.md`](./docs/wsl-setup.md).

## Quick start

```bash
gh repo clone mustry-academy/cicd-lab-06-secrets-db-and-modules
cd cicd-lab-06-secrets-db-and-modules
cp .env.example .env
scripts/setup.sh       # brings up the stack, waits for all three gateways, prints credentials
scripts/validate.sh    # must be green before you start the lab
```

Once setup finishes you have three Ignition gateways and a TimescaleDB:

| Service | URL | What it is |
|---|---|---|
| `local` | http://localhost:8088 | Your working gateway — bind-mounted from `./projects/` + `./services/config/` |
| `test` | http://localhost:8089 | Empty until `deploy.yml` runs (push to `main`, or manual dispatch) — deployed files visible under `./gateways/test/` |
| `production` | http://localhost:8090 | Same, populated by a manual `deploy.yml` run with `target=production` |
| `timescaledb` | localhost:5432 | Databases `ignition_local_development` / `ignition_test` / `ignition_production`; logins `ignition` (r/w) and `reporting` (read-only) |

Login with the credentials from `.env` (`GATEWAY_ADMIN_USERNAME_LOCAL/_TEST/_PRODUCTION`, default `admin / password`).

> **Trial mode:** each gateway runs in 2-hour trial mode. Reset via *Gateway → Config → Licensing → Reset Trial* — unlimited and entirely legal for development.

> **Stuck?** See [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md). Before opening a PR, run `scripts/validate.sh` (JSON / `.deployignore` / secret scan).

## Lab structure

The lab is a warm-up plus three parts — [`exercises/lab.md`](./exercises/lab.md) is the source of truth, [`slides/assignment.html`](./slides/assignment.html) mirrors it:

| Part | Topic | Gate |
|---|---|---|
| Warm-up | Deploy to develop and production; find both db-connections **Faulted** while the pipeline is green | the diagnosis question |
| 1 (±30 min) | Passwords → secret files → file-type secret provider → **referenced secrets**; fix develop through a full PR → pipeline deploy | both connections Valid on develop, fixed by the pipeline |
| 2 (±20 min) | A schema change as a golang-migrate `0002` up/down pair; `deploy.yml` migrates test **before** it ships | green run: migrate → ship → scan → verify |
| 3 (±10 min) | A spare `.modl` deployed with headless license/cert acceptance in `services/modules.json` | module **Running** on test, hands-free |

Reference reading: [`docs/secrets-management.md`](./docs/secrets-management.md) and [`db-migration/MIGRATIONS.md`](./db-migration/MIGRATIONS.md).

## Repo layout

```
cicd-lab-06-secrets-db-and-modules/
├── README.md
├── docker-compose.yaml                 ← three gateways + TimescaleDB + runner. Passwords are
│                                          still env vars — Part 1A moves them to file secrets
├── .env.example                        ← copy to .env before running
├── .deployignore                       ← what NOT to copy onto test/production gateways (incl. secrets/)
├── secrets/                            ← file-based secrets; only *.example files are tracked
├── db-init/                            ← BOOTSTRAP: creates env databases + the reporting login
│                                          (runs once, on first DB volume init — never again)
├── db-migration/
│   ├── MIGRATIONS.md                   ← the two rules the tool won't enforce for you
│   └── migrate/                        ← numbered golang-migrate pairs; 0002 is yours (Part 2)
├── .github/workflows/
│   ├── ci.yml                          ← PR validation: linters + JSON checks + secret scan
│   └── deploy.yml                      ← push to main → test; manual dispatch → test or production.
│                                          You add the Materialize-secrets (1C) and Migrate (2B) steps
├── exercises/lab.md                    ← the lab
├── docs/                               ← reference reading + troubleshooting
├── instructor-notes/                   ← answer key (read after solo work)
├── scripts/
│   ├── setup.sh / teardown.sh / lib.sh / scan.sh   ← stack management (from Lab 04)
│   ├── migrate.sh                      ← golang-migrate in Docker (up / down / version, --database)
│   └── validate.sh                     ← local mirror of ci.yml, incl. the secret scan
├── projects/                           ← Perspective projects (bind-mounted into `local`)
├── gateways/                           ← test/production gateway state (gitignored bind mounts)
├── services/
│   ├── config/                         ← gateway config; the two db-connections live under
│   │                                      resources/{core,local-development,test,production}/ignition/database-connection/
│   └── modules.json                    ← module enablement manifest (Part 3 adds the spare)
└── third-party-modules/                ← bundled .modl binaries — incl. the spare one Part 3 deploys
```

## The two database connections (the warm-up's broken state)

The local gateway has two connections to the shared TimescaleDB, and they are **deliberately seeded broken for test/production**:

| Connection | Login | Target | Per-env override? |
|---|---|---|---|
| `TimescaleDB` | `ignition` (r/w) | `ignition_<env>` | `local-development`/`test`/`production` overrides exist — the pattern to copy |
| `TimescaleDB_Reports` | `reporting` (read-only) | `ignition_local_development` | **core only** — develop inherits the wrong database (Part 1C fixes this) |

Both passwords are **embedded** secrets in the committed config, encrypted under **custom secrets-management keys** that are committed for the local gateway (`services/config/ignition/keys/` + `IGNITION_ROOT_KEY_PASSWORD` in the compose file) and deliberately excluded from the deploy payload (`.deployignore`). So your local gateway decrypts them, and develop/production fault with `Unable to decrypt ciphertext` — a green pipeline and broken connections, which is the warm-up's whole point: a config-only deploy cannot carry password values (they must never be in Git) nor the per-environment database target. Part 1 replaces the whole construction with **referenced** secrets from a file-type provider, and the deploy workflow materializes the files from GitHub environment secrets. (Committing key files is a real-world anti-pattern — that's the seed being deliberately naive; see `docs/secrets-management.md`.)

## The CI/CD workflows

| File | Trigger | Runner | Purpose |
|---|---|---|---|
| [`ci.yml`](./.github/workflows/ci.yml) | PR to `main` | `ubuntu-latest` (free) | Linters, JSON validity, `.deployignore` syntax, **secret scan**. |
| [`deploy.yml`](./.github/workflows/deploy.yml) | Push to `main` (deploy paths only); manual dispatch with `target: test\|production` | `[self-hosted, lab06]` | File-based deploy via `docker cp` + hot scan. Ships secret files (once your 1C step materializes them) and the module manifest (restarting the gateway only when it changed). |

Both deploy targets need:

- The bundled self-hosted runner (`github-runner` service in `docker-compose.yaml`) registered against your fork with the `lab06` label — it auto-registers using the `repo`-scope PAT in `RUNNER_GITHUB_PAT` (see `.env`; reuse your Lab 04 token).
- A GitHub **environment** per target with the right secrets + variables:

| Scope | Name | Type | Purpose |
|---|---|---|---|
| Environment `lab-gateway-test` | `IGNITION_API_KEY` | Secret | Token with Project Scan + Config Scan permission (the pre-provisioned `cicd` token from `.env.example` works) |
| Environment `lab-gateway-test` | `POSTGRES_PASSWORD`, `REPORTING_PASSWORD` | Secrets | **You add these in Part 1C** — the Materialize step turns them into secret files on the test host |
| Environment `lab-gateway-test` | `IGNITION_URL`, `IGNITION_CONTAINER` | Variables (optional) | Default to `http://gateway-test:8088` / `lab06-gateway-test` (bundled-runner case) |
| Environment `lab-gateway-production` | (same set) | | Defaults: `http://gateway-production:8088` / `lab06-gateway-production` |

## Database migrations

`db-init/` is bootstrap; `db-migration/migrate/` is deployment. Day-to-day:

```bash
scripts/migrate.sh up                           # apply pending migrations on ignition_local_development
scripts/migrate.sh up --database ignition_test   # same, against test (what your 2B step runs)
scripts/migrate.sh version                      # current position + dirty flag
docker exec lab06-timescaledb psql -U ignition -d ignition_local_development \
  -c 'SELECT * FROM schema_migrations;'         # read the ledger directly
```

See [`db-migration/MIGRATIONS.md`](./db-migration/MIGRATIONS.md) for the rules ("always pairs", "never edit a deployed migration").

## Licence

Apache 2.0 — see [`LICENSE`](./LICENSE).
