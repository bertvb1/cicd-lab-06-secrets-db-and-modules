# Lab 06 — Multi-gateway deployments & environment promotion

**Duration:** ~180 minutes (09:00 – 12:00, Day 4 morning)

* 09:00 – 10:00 — Teaching: multi-gateway topologies, promotion, config scopes (`slides/teaching.html`)
* 10:00 – 11:00 — We do together (instructor drives, everyone follows)
* 11:00 – 12:00 — You do (breakout rooms) — `slides/assignment.html`
* 12:00 — wrap-up & handoff to Day 4 afternoon (secrets — Lab 07)

<!-- TODO(instructors): confirm block letters (assumed E = promotion, F = config options)
     and align with labs 04/05 READMEs. -->

## Goal

You should leave this lab able to:

- Sketch the promotion pipeline **local → dev → test → prod** and say precisely what moves a build from each stage to the next (auto on green, release branch, human approval).
- Explain **build-once / promote-many** across three deployed stages, and *prove* it by comparing image digests on dev, test, and prod.
- Add a **new environment** (test) to an existing pipeline: compose service, database, workflow, GitHub environment.
- Put a **human approval gate** in front of prod using GitHub environment required reviewers — with zero workflow changes.
- Use **Ignition 8.3 config scopes** deliberately: explain the `external → core → <env>` inheritance chain, read `config-mode.json`, and build a `tst` overlay that redirects the DB connection.
- Classify any configuration value into **core / per-env overlay / secret** and defend the choice.
- (Stretch) Fan a release out to a fleet of gateways with a GitHub Actions **matrix**, and roll the fleet back.

## Pre-flight

```bash
cp .env.example .env      # fill in RUNNER_REPO_URL + RUNNER_GITHUB_PAT (your fork!)
scripts/setup.sh          # TODO(infra): script not built yet — brings up local/dev/test/prod + DB + runner
scripts/build-image.sh    # you'll promote this image during the lab
```

You'll need the same fork + PAT + GHCR setup as Lab 05 (see [`README.md`](../README.md#prerequisites)). If you finished Lab 05, this will feel familiar — that's the point.

Read ahead if you like: [`docs/multi-gateway-promotion-pattern.md`](../docs/multi-gateway-promotion-pattern.md).

---

## Warm-up (together, ~10 min)

Read-only spelunking on the freshly started stack. Everything you find here is the raw material for both parts.

### Warm-up 1 — find the scope machinery you've been using all week

1. `ls services/config/resources/` — you'll see `external/`, `core/`, `loc/`, `dev/`, `prd/`. Note **there is no `tst/`** — that's yours to build in Part 2.
2. `cat services/config/resources/dev/config-mode.json` — find the `parent` field. Follow the chain: `dev → core → external`. Write the chain in `NOTES.local.md`.
3. Find where each environment's database is decided:
   ```bash
   grep -r "connectURL" services/config/resources/*/ignition/database-connection/
   ```
   Same connection *name*, different URL per scope. That's the whole trick.
4. Which scope does each gateway boot with?
   ```bash
   docker inspect lab06-ignition-dev  --format '{{ .Config.Cmd }}'   # look for -Dignition.config.mode=…
   docker inspect lab06-ignition-prod --format '{{ .Config.Cmd }}'
   ```

### Warm-up 2 — establish the baseline

1. What image is each gateway running right now?
   ```bash
   for gw in dev test prod; do
     echo "$gw → $(docker inspect -f '{{ .Config.Image }}' lab06-ignition-$gw 2>/dev/null || echo 'not running')"
   done
   ```
2. Note in `NOTES.local.md`: which gateways run the base (empty) image, and which — if any — already run a built one. Everything you do in Part 1 changes this answer.

---

## Part 1 (Block E) — Stand up the test stage & promote through gates

**~30 min solo.** The pipeline exists for dev and prod (Lab 05's shape). You add the middle stage and the gate.

### 1.1 — Bring up the test gateway

<!-- TODO(infra): compose ships with ignition-test scaffolded; confirm whether it's commented out
     (students uncomment) or up-from-setup (students only verify). Steps below assume "verify". -->

1. `docker compose ps` — confirm `lab06-ignition-test` is up and healthy on http://localhost:8091.
2. Confirm it boots with `-Dignition.config.mode=tst` (docker inspect, as in the warm-up).
3. Confirm the `ignition_tst` database exists:
   ```bash
   docker exec lab06-timescaledb psql -U ignition -l | grep ignition_
   ```
4. Log in to :8091 — it's an **empty gateway on the base image**. Deploying something onto it is the next step.

### 1.2 — Ship to dev (the Lab 05 muscle memory)

1. Branch `feature/...` off `develop`, make a visible change to the example project (e.g. edit a Perspective view), PR into `develop`, merge.
2. `deploy.yml` builds + pushes `:sha-<short>` + `:dev` and recreates **dev**. Verify the change on :8089.

### 1.3 — Promote to test with a release branch

1. Cut the freeze point:
   ```bash
   git checkout develop && git pull
   git checkout -b release/1.0
   git push -u origin release/1.0
   ```
2. `promote.yml` fires on the `release/**` push: **no build** — it re-tags `:dev` → `:test` and recreates the **test** gateway from it.
3. Verify your change is live on :8091, then prove the promotion:
   ```bash
   docker inspect -f '{{ index .RepoDigests 0 }}' lab06-ignition-dev
   docker inspect -f '{{ index .RepoDigests 0 }}' lab06-ignition-test
   ```
   Same digest → same bytes. Test is now validating *exactly* what dev ran.
4. Meanwhile `develop` is free to move on — merge another small feature into `develop` and watch **dev change while test stays frozen**. Write down why that separation matters.

### 1.4 — Gate prod behind a human

1. In your fork: *Settings → Environments → `lab-gateway-prod` → Required reviewers* → add yourself.
2. Release the Git Flow way:
   ```bash
   git checkout main && git pull
   git merge --no-ff release/1.0 -m "Release v1.0.0"
   git push origin main
   git tag v1.0.0 && git push origin v1.0.0
   ```
3. `release.yml` fires: `promote` re-tags **`:test`** (not `:dev`! dev has already drifted) → `:v1.0.0` + `:prod`… and then the `deploy` job **waits**.
4. Find the yellow "Review pending deployments" banner in the workflow run. Approve it. Watch prod recreate.
5. Prove the whole chain — all three digests:
   ```bash
   for gw in test prod; do docker inspect -f '{{ index .RepoDigests 0 }}' lab06-ignition-$gw; done
   ```
   test ≡ prod. (dev may differ — it moved on in 1.3.4. Explain why that's correct.)

**Gate ✅:** test and prod report the same image digest, and your workflow run shows a manual approval on the prod deploy. Don't start Part 2 until this is true.

---

## Part 2 (Block F) — Configuration options explored

**~30 min solo.** Same artifact everywhere — so where do the differences live? You build one and classify the rest.

### 2.1 — Build the `tst` scope overlay

Right now the test gateway resolves config as `tst → core → external`, but the `tst/` folder doesn't exist — so it silently gets **core's** DB connection (pointing at the wrong database). Fix that:

1. Create the scope descriptor `services/config/resources/tst/config-mode.json`:
   ```json
   {
     "title": "tst",
     "description": "tst",
     "enabled": true,
     "inheritable": true,
     "parent": "core"
   }
   ```
2. Create the DB override — copy `dev/ignition/database-connection/TimescaleDB/` to `tst/ignition/database-connection/TimescaleDB/` and change the `connectURL` database to `ignition_tst`.
   <!-- [VERIFY] the copied config.json contains an encrypted password blob from the dev gateway's
        system — confirm it decrypts/re-encrypts cleanly on another gateway, or document the
        password-reset step needed. This is a known sharp edge to test before the course. -->
3. Ship it **through the pipeline** — this is the punchline of the whole lab:
   feature branch → PR → `develop` (dev rebuilds; dev *ignores* `tst/` because it boots `mode=dev`) → push to `release/1.1` → test recreates and now resolves `tst → core`.
4. Verify on :8091 (*Config → Databases → Connections*): the TimescaleDB connection now points at `ignition_tst`. The **same image** on dev still points at `ignition_dev`. One artifact, per-gateway behavior.

### 2.2 — The config inventory drill

In `NOTES.local.md`, classify each of these into **core** (same everywhere, in git), **overlay** (per-env, in git), or **secret** (per-env, NOT in git) — and note *why*:

| # | Setting |
|---|---|
| 1 | Database `connectURL` |
| 2 | Database password |
| 3 | Historian provider settings |
| 4 | OPC UA server endpoint for the plant PLCs |
| 5 | Identity provider (IdP) configuration |
| 6 | Perspective session timeout |
| 7 | Gateway admin password |
| 8 | Alarm notification SMTP server |
| 9 | Which modules are enabled (`modules.json`) |
| 10 | Gateway memory limit (`-m 1024`) |

Then compare with [`docs/multi-gateway-promotion-pattern.md`](../docs/multi-gateway-promotion-pattern.md#the-three-buckets) — and argue with it where you disagree. (Several of these are genuinely debatable; #10 isn't even config-scope territory — it's compose/boot-time. Knowing *which layer* a knob belongs to is the skill.)

### 2.3 — What we deliberately did NOT solve

Look at the `password` block inside any `database-connection/config.json`. It's an encrypted blob, tied to the gateway that wrote it — and it's sitting in git. Write down (a) why this is not OK for a real customer, (b) what you'd want instead. That's Day 4 afternoon (Lab 07 — secrets management).

---

## Definition of done

- [ ] The test gateway is up on :8091 and boots with config mode `tst`.
- [ ] A push to `release/1.0` promoted the `:dev` image to test **without rebuilding** (digests match).
- [ ] The `v1.0.0` release **waited for your approval** before recreating prod, and promoted from `:test`.
- [ ] You showed dev drifting ahead while test stayed frozen, and can explain why prod promotes from `:test` not `:dev`.
- [ ] The `tst/` scope overlay exists, shipped through the pipeline, and the test gateway's DB connection points at `ignition_tst`.
- [ ] Your config inventory (2.2) is written up in `NOTES.local.md` with reasons.

## Stretch challenges `[OPTIONAL]`

- **Fan-out.** `docker compose --profile fanout up -d` to start `prod-b` (:8092). Extend `release.yml`'s deploy job with a matrix over `[prod, prod-b]`, re-run the release, and verify **both** gateways report the same digest. <!-- TODO(infra): matrix stub in release.yml, prod-b service under the fanout profile -->
- **Canary.** Set `max-parallel: 1` and order the matrix `[prod-b, prod]` so prod-b takes the release first; fail its healthcheck on purpose (stop the DB?) and watch the rollout halt before touching prod.
- **Fleet rollback.** Ship a `v1.1.0`, then use `release.yml`'s `workflow_dispatch` with `v1.0.0` to roll the whole fleet back. Time it.
- **Env indicator.** Add a Perspective view that shows which config mode / database the gateway is running, so promotion is visible in the browser without docker commands. <!-- [VERIFY] cleanest way to read the active config mode from a view -->

## Debrief (10 min)

- Prod promotes from `:test`, not `:dev`, and not the tagged commit SHA. Walk the failure that each of the other two choices allows.
- The release branch froze test while develop moved on. What team-size / release-cadence threshold makes this worth the ceremony? When would you skip the test stage entirely?
- One image carries *every* environment's config overlay. What's in that image that a hostile reader of your registry would enjoy? (Bridge to Lab 07.)
- The approval gate is one person clicking a button. What would you *actually* want checked before prod at a customer site — and which of those checks can be a workflow job instead of a human?
- We scaled stages vertically (dev→test→prod). The matrix stretch scaled horizontally (prod×N). Which real topologies at *your* plants map to which?
