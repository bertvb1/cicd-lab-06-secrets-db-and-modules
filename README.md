# Lab 06 — Multi-gateway deployments & environment promotion

Day 4 (morning) of the [CI/CD for Ignition Masterclass](https://github.com/mustry-academy/cicd-masterclass).
<!-- TODO(instructors): lab 04's README calls multi-gateway "Block D" while lab 05 claims blocks C+D.
     Decide the canonical block letters for Day 4 morning (this README assumes "Blocks E and F") and
     fix the cross-references in labs 04/05. -->

> Widen the pipeline from Day 3 into a real promotion flow: **local → dev → test → prod**. One image is built once, then *promoted* stage by stage — automatically to dev, on a release branch to test, and through a **human approval gate** to prod. Along the way you take explicit control of **what differs per environment** using Ignition 8.3 config scopes (`-Dignition.config.mode`), so a single artifact carries every environment's configuration and each gateway picks its own at boot.

This lab builds directly on [Lab 04 (file-based deploy)](https://github.com/mustry-academy/cicd-lab-04-ignition-file-based-deploy) and [Lab 05 (image-based deploy)](https://github.com/mustry-academy/cicd-lab-05-ignition-image-based-deploy). Both of those ended at a two-stage dev → prod story on a single machine. Real plants have more gateways than that — an acceptance/test tier, multiple production lines or sites, edge boxes — and the interesting questions all live in the gaps between them: *what promotes a build from one stage to the next, and what is allowed to differ between two gateways running "the same" release?*

## What changes from Lab 05

| | Lab 05 (image-based) | Lab 06 (multi-gateway) |
|---|---|---|
| Stages | local → dev → prod | local → dev → **test** → prod (+ optional prod-b fan-out) |
| Promotion to prod | tag `v*` re-tags `:dev` | tag `v*` re-tags **`:test`** — prod only ever runs what test validated |
| Gate before prod | none (optional stretch) | **required reviewer** on the `lab-gateway-prod` environment |
| Per-env config | shipped silently (`loc`/`dev`/`prd` scopes existed but we never talked about them) | **taught explicitly** — you build the `tst` scope overlay yourself |
| Fleet | one prod gateway | matrix deploy to N gateways (stretch) |

The artifact and the delivery mechanism are unchanged from Lab 05: a versioned Docker image, deployed by pull + recreate. What's new is everything *around* it.

## Prerequisites

- A fork of this repo, **with Actions enabled** (forks ship with workflows disabled — open the *Actions* tab and enable them).
- A GitHub Personal Access Token with `repo` scope in `.env` as `RUNNER_GITHUB_PAT` (the bundled runner auto-registers against your fork).
- **≥ 10 GB free RAM for Docker** — four Ignition gateways at 1 GB each (five with the fan-out stretch), plus TimescaleDB, the runner, and Docker overhead. <!-- [VERIFY] measure the real footprint once the compose stack exists; 4 gateways may need the memory limits lowered to fit 8 GB machines -->
- _Background:_ [Lab 05](https://github.com/mustry-academy/cicd-lab-05-ignition-image-based-deploy) — this lab reuses its Dockerfile, GHCR flow, and Git Flow branching. Lab 06 stands alone technically (setup brings up a fresh stack), but the *concepts* of build-once/promote-many are assumed.

## Quick start

```bash
gh repo clone mustry-academy/cicd-lab-06-multi-gateway-deploy
cd cicd-lab-06-multi-gateway-deploy
cp .env.example .env
scripts/setup.sh    # brings up the stack, waits for the gateways, prints credentials
```

Once setup finishes you have **four** Ignition gateways (five with `--profile fanout`):

| Gateway | URL | Config scope | What runs there |
|---|---|---|---|
| `local` | http://localhost:8088 | `loc` | Bind-mounted from `./projects/` + `./services/config/` — your **authoring** gateway. |
| `dev` | http://localhost:8089 | `dev` | The image `deploy.yml` builds on push to **`develop`**. |
| `prod` | http://localhost:8090 | `prd` | The image `release.yml` promotes on tag `v*` — **after a human approves**. |
| `test` | http://localhost:8091 | `tst` | The image `promote.yml` re-tags from `:dev` on push to **`release/*`**. |
| `prod-b` | http://localhost:8092 | `prd` | Optional fan-out target (`docker compose --profile fanout up -d`). Stretch only. |

<!-- TODO(instructors): port layout keeps dev=8089/prod=8090 for muscle-memory continuity with labs 04/05,
     which puts test at 8091 (out of pipeline order). If you prefer pipeline order
     (dev 8089, test 8090, prod 8091), renumber here, in the compose file, and in both slide decks. -->

Login with the credentials from `.env` (`GATEWAY_ADMIN_USERNAME_LOCAL/_DEV/_TEST/_PROD`, default `admin / lab06password`).

> **Trial mode:** each gateway runs in 2-hour trial mode. Reset via *Gateway → Config → Licensing → Reset Trial* — unlimited and legal for development. dev/test/prod are recreated from a fresh image on each deploy, so their trial clocks reset on deploy too.

> **Stuck?** See [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md) *(TODO — not written yet)*. Before opening a PR, run `scripts/validate.sh` (mirrors CI).

## Lab structure

| Part | Topic | Exercise |
|---|---|---|
| 1 (Block E) | Stand up the test stage & promote through gates | [`exercises/lab.md`](./exercises/lab.md) |
| 2 (Block F) | Configuration options explored — parameterize per environment | [`exercises/lab.md`](./exercises/lab.md) |

Reference reading sits alongside: [`docs/multi-gateway-promotion-pattern.md`](./docs/multi-gateway-promotion-pattern.md).

## Repo layout

```
cicd-lab-06-multi-gateway-deploy/
├── README.md
├── Dockerfile                          ← same shape as Lab 05: projects + config + modules baked in   [TODO]
├── .dockerignore                                                                                      [TODO]
├── docker-compose.yaml                 ← local/dev/test/prod gateways (+prod-b profile) + TimescaleDB
│                                          + bundled self-hosted runner                                [TODO]
├── .env.example                                                                                       [TODO]
├── .github/
│   └── workflows/
│       ├── ci.yml                      ← PR validation (JSON, hadolint, actionlint, build smoke test) [TODO]
│       ├── deploy.yml                  ← push to develop → build+push image → recreate DEV            [TODO]
│       ├── promote.yml                 ← push to release/* → re-tag :dev → :test → recreate TEST      [TODO]
│       └── release.yml                 ← tag v* → re-tag :test → :vX.Y.Z + :prod → recreate PROD
│                                          (waits on the lab-gateway-prod approval gate)               [TODO]
├── exercises/
│   └── lab.md                          ← the full lab: warm-up, Part 1 (promotion), Part 2 (config)
├── docs/
│   ├── multi-gateway-promotion-pattern.md  ← reference reading (seeded)
│   └── TROUBLESHOOTING.md                                                                             [TODO]
├── instructor-notes/                                                                                  [TODO]
├── scripts/
│   ├── setup.sh / teardown.sh / lib.sh                                                                [TODO]
│   ├── build-image.sh                  ← local mirror of the CI build                                 [TODO]
│   ├── promote-image.sh                ← local mirror of the promote step (re-tag, no rebuild)        [TODO]
│   ├── deploy-image.sh                 ← recreate a named gateway from an image                       [TODO]
│   └── validate.sh                                                                                    [TODO]
├── db-init/
│   └── 01-create-env-databases.sql     ← ignition_loc/_dev/_tst/_prd (+_prd_b?)                       [TODO]
├── projects/example-project/           ← copy from Lab 05                                             [TODO]
├── services/
│   ├── config/resources/{external,core,loc,dev,prd}/  ← copy from Lab 05; students BUILD tst/        [TODO]
│   └── modules.json                                                                                   [TODO]
└── third-party-modules/                ← copy from Lab 05                                             [TODO]
```

## The promotion pipeline

```
feature/* ─PR→ develop ──push──▶ deploy.yml  ── build+push :sha :dev ──▶ DEV   (automatic)
                  │
                  └── release/1.x ──push──▶ promote.yml ── re-tag :dev → :test ──▶ TEST  (release branch = freeze)
                          │
                          └─PR→ main ──tag vX.Y.Z──▶ release.yml ── re-tag :test → :vX.Y.Z + :prod ──▶ PROD
                                                                     ▲
                                                        required reviewer approves here
```

Three invariants the lab keeps hammering:

1. **Build once.** The image is built exactly once, on the push to `develop`. Every later stage is a server-side re-tag (`docker buildx imagetools create`) — the digest never changes.
2. **Promote only from the stage below.** Prod runs what test validated (`:test`), never what dev happens to be running at tag time.
3. **One artifact, every environment's config.** The image contains *all* scope overlays (`loc`, `dev`, `tst`, `prd`); the boot flag `-Dignition.config.mode=<scope>` decides which one a gateway resolves. No per-environment rebuilds, no hand-edits after deploy.

## Configuration scopes (the Block F topic)

Ignition 8.3 organizes gateway config as `config/resources/<scope>/…`, with scopes forming an inheritance chain declared in each scope's `config-mode.json`:

```
external  →  core  →  { loc | dev | tst | prd }
(defaults)   (shared, versioned)   (per-env overlays, versioned)
```

Labs 04 and 05 shipped `loc`/`dev`/`prd` overlays without ever discussing them — the dev gateway pointed at `ignition_dev` and prod at `ignition_prd` "by magic". In Part 2 you build the `tst` overlay yourself and classify every configuration knob into one of three buckets:

| Bucket | Example | Where it lives |
|---|---|---|
| Same everywhere | historian provider settings, identity provider, tag providers | `core/` — in git |
| Differs per env, not secret | DB `connectURL`, OPC UA endpoint, gateway name | scope overlay (`dev/`, `tst/`, `prd/`) — in git |
| Secret | DB passwords, API keys, cloud credentials | **not in git** — Day 4 afternoon (Lab 07) |

## The CI/CD workflows

| File | Trigger | Runner(s) | Purpose |
|---|---|---|---|
| `ci.yml` | PR to `develop` or `main` | `ubuntu-latest` | Validate JSON, hadolint, actionlint, no-push image build. |
| `deploy.yml` | Push to `develop` | build: `ubuntu-latest` · deploy: `[self-hosted, lab06]` | Build + push `:sha-<short>` + `:dev`, recreate **dev**. |
| `promote.yml` | Push to `release/**`, manual | promote: `ubuntu-latest` · deploy: `[self-hosted, lab06]` | Re-tag `:dev` → `:test` (**no rebuild**), recreate **test**. |
| `release.yml` | Tag `v*` (on `main`), manual | promote: `ubuntu-latest` · deploy: `[self-hosted, lab06]` | Re-tag `:test` → `:vX.Y.Z` + `:prod` (**no rebuild**), recreate **prod** — gated by `lab-gateway-prod` required reviewers. Manual dispatch with an older tag = rollback. |

GitHub **environments** used: `lab-gateway-dev`, `lab-gateway-test`, `lab-gateway-prod`. The prod one carries the required-reviewer gate (set up in Part 1 — no workflow change needed). GHCR auth is the built-in `GITHUB_TOKEN`, publishing to `ghcr.io/<your-fork-owner>/cicd-lab-06-ignition`, exactly like Lab 05.

## TODO — infrastructure still to build

This repo currently contains the README, exercises outline, seed doc, and slide decks. Still to build before the course runs (mostly copy-and-extend from Lab 05):

- [ ] `docker-compose.yaml` — Lab 05's file + `ignition-test` service (port 8091, `-Dignition.config.mode=tst`, `IGNITION_TEST_IMAGE` var) + `ignition-prod-b` under a `fanout` profile (port 8092) + runner labels `self-hosted,lab06`.
- [ ] `db-init/01-create-env-databases.sql` — add `ignition_tst`. Decide whether prod-b shares `ignition_prd` or gets its own DB.
- [ ] `Dockerfile`, `.dockerignore`, `.env.example`, `.gitattributes` — copy from Lab 05, rename lab05→lab06.
- [ ] Workflows: `ci.yml` / `deploy.yml` (copy), `promote.yml` (new — `release/**` trigger, re-tag `:dev`→`:test`), `release.yml` (change promotion source from `:dev` to `:test`; keep `workflow_dispatch` rollback input). Stretch: a `matrix` deploy job over `[prod, prod-b]` with `max-parallel: 1`.
- [ ] `scripts/` — `setup.sh`/`teardown.sh`/`lib.sh`/`validate.sh` (copy + extend to wait for 4 gateways), `promote-image.sh` (new: local re-tag mirror), `deploy-image.sh` (accept `test`/`prod-b` targets).
- [ ] `services/config/resources/` — copy from Lab 05 **without** a `tst/` folder (students create it in Part 2). Ship a `tst/` reference in `instructor-notes/`.
- [ ] `projects/example-project/`, `third-party-modules/`, `services/modules.json` — copy from Lab 05. Consider adding an env-indicator Perspective view that displays the gateway's config mode / DB name so promotion is *visible* in the browser. <!-- [VERIFY] nicest way to surface the active config mode in a view — system property? tag? -->
- [ ] `instructor-notes/` — answer keys for Part 1 and Part 2 (incl. the finished `tst/` overlay and the config-inventory classification).
- [ ] `docs/TROUBLESHOOTING.md` — Lab 05's plus: approval gate never prompts (reviewer not set / wrong environment name), test gateway boots with core config only (missing/bad `config-mode.json` parent), promote fires from the wrong branch pattern.
- [ ] Verify RAM guidance with the real stack; consider dropping per-gateway memory limits so the lab fits 8 GB machines.

## Licence

Apache 2.0 — see `LICENSE`. <!-- TODO: copy LICENSE file from lab 05 -->
