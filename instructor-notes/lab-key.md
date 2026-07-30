# Lab 06 — instructor key & pre-course verification list

Two sections: what MUST be verified/re-seeded on a live stack before the
course runs, and the answer key for the parts.

## A. Seeding mechanics (verified live on 8.3.8) & what's left to check

### A1. How the warm-up's broken state works — VERIFIED

Empirical findings from a live run (2026-07-13, Ignition 8.3.6; JAR bundling re-verified identical on 8.3.8 on 2026-07-24):

- **The default embedded-secrets key is identical on every Ignition
  installation.** A ciphertext created on one default-key gateway decrypts on
  any fresh container. So "committed embedded ciphertext" is NOT
  gateway-specific out of the box — Lab 04's committed ciphertexts worked on
  every student machine for exactly this reason.
- Therefore the seed uses **custom keys**: `services/config/ignition/keys/`
  (root.json + kek.json, generated with `ignition-secrets-tool.sh`, root-key
  passphrase `lab06-root-key-pass` passed to the local-development gateway via
  `IGNITION_ROOT_KEY_PASSWORD` in docker-compose.yaml). The keys are
  deliberately COMMITTED (dummy values) so every student's local gateway
  decrypts the seeded ciphertexts, and excluded from the deploy payload via
  `.deployignore`, so test/production cannot.
- A gateway with custom keys still decrypts default-key ciphertexts (the
  MQTT / OPC UA seeds keep working everywhere). A gateway WITHOUT the custom
  keys fails on custom-KEK ciphertexts with `Unable to decrypt ciphertext`.
- Verified end state: local gateway — both connections + historian Valid
  (live sessions for `ignition` and `reporting`); test gateway after a
  simulated deploy — `TimescaleDB` and `TimescaleDB_Reports` both Faulted
  with `Unable to decrypt ciphertext` (the historian provider on test faults
  the same way; that's expected seed noise, mention it if someone spots it).
- All custom-KEK ciphertexts (TimescaleDB core/local-development/test/production, Reports core,
  historian core/local-development) encrypt the passwords that `db-init` actually sets:
  `lab06-postgres-pw` (user `ignition`) and `lab06-reporting-pw` (user
  `reporting`) — same values as `secrets/*.example`.

To re-mint ciphertexts (e.g. after rotating the seed passwords or keys), use
[`mint-embedded-secret.py`](./mint-embedded-secret.py):

```bash
python3 -m venv .venv && .venv/bin/pip install jwcrypto
.venv/bin/python3 instructor-notes/mint-embedded-secret.py . lab06-root-key-pass 'new-password'
# paste the printed JWE object into the resource's "password": {"type": "Embedded", "data": …}
```

There is no plaintext-ingestion shape for secrets in config files (tested:
the gateway parses `data` strictly as a flattened JWE), and no REST endpoint
for it — mint the JWE, or set the value through the gateway UI on a gateway
that holds the committed keys and commit the rewritten config.json.

### A2. Deploy pipeline — VERIFIED end-to-end (2026-07-13, run on the
### upstream repo with the bundled runner)

All four flows ran green through the actual GitHub Actions pipeline:

- **Warm-up**: `deploy.yml` green to test (push + dispatch) and production
  (dispatch, `target=production`); both gateways' connections Faulted with
  `Unable to decrypt ciphertext`; local Valid.
- **1C**: Materialize + the pre-wired "Ship secret files" step land
  `postgres_password` / `reporting_password` at `/run/secrets/` with mode
  600. (Connections-go-Valid still depends on 1B's provider, which is UI
  work — see A4.)
- **2B**: `scripts/migrate.sh up --database ignition_test` runs from inside
  the containerized runner; test's `schema_migrations` reached version 2
  before the ship steps.
- **Part 3**: manifest change → detected → gateway restart →
  `Starting up module 'com.mussonindustrial.embr.periscope'` → Running.
- **ci.yml**: all three jobs (Lint incl. ign-lint, Validate, Secret scan)
  green on PR #2.

**Re-run on a real personal FORK, whole lab end to end (2026-07-30).** Nothing
left open: warm-up (dispatch to both targets, both Faulted), 1A–1D, 2A–2B, 3
and a `v1.1.0` tag all green, and verified from the outside rather than from the
run log — `pg_stat_activity` shows the test gateway connected to
`ignition_test` as **both** `ignition` and `reporting` and production likewise
to `ignition_production` (so both connections Valid, `TimescaleDB_Reports` on
its own database), `schema_migrations` at version 2 on test *and* production
applied by the runs, three modules Running on local and test. The
tag → `release.yml` → `deploy.yml` (`workflow_call`, `target: production`) path
is confirmed: it also migrates `ignition_production` and restarts for the module
manifest, i.e. the steps students add in 1C/2B do reach production unchanged.

Fork-specific gotchas that cost time and are worth saying out loud on the day:

- **A fresh fork blocks every automatic trigger** until someone clicks
  *Actions → "I understand my workflows, go ahead and enable them"*. Symptom:
  PR/merge/tag produce **no run and no error**. `repos/…/actions/permissions`
  already reports `enabled:true`, per-workflow `/enable` calls change nothing —
  there is no API for that button. `Run workflow` (workflow_dispatch) is the
  only thing that works before the click, which is why the warm-up can look
  fine while 1D silently does nothing.
- A fork inherits `default_workflow_permissions: read`. Harmless here (this
  lab's workflows only need `contents: read`), but it is what breaks Lab 05's
  GHCR stretch: a fork cannot push packages with `GITHUB_TOKEN` at all
  (`denied: permission_denied: write_package`, even with `Packages: write` in
  the job's token).
- `gh auth token` has no `delete_repo` scope, so cleaning up student forks is a
  web-UI job (or `gh auth refresh -h github.com -s delete_repo` first).

**CLOSED 2026-07-30: the tag release flow is E2E-verified.** 1D's production
promotion uses the Lab 04 routing — a `v*` tag fires the thin `release.yml`,
which calls `deploy.yml` (workflow_call, `target: production`,
`secrets: inherit`). Confirmed on a fork: the called run resolves the
`lab-gateway-production` environment (its `IGNITION_API_KEY`,
`POSTGRES_PASSWORD`, `REPORTING_PASSWORD`), materializes the secret files,
migrates `ignition_production` and ships — green in ~15 s when production has
been deployed to before (no first-deploy restart).

The runnable answer key lives on the **`rehearsal/lab-solutions`** branch
(PR #2, draft, never to be merged): the Materialize + Migrate steps at their
insertion points, the `TimescaleDB_Reports` test override, the `0002` pair,
and the enabled Periscope entry. To re-verify any flow, dispatch `deploy.yml`
from that branch with `target=test`.

### A5. The temp identity — closed for good (2026-07-30)

The stash-during-commissioning guard (A1/A2) only ever asked the CONFIG TREE
"is this a first boot?" (`does user-source/default exist?`), while the gateway
answers it from its DATA VOLUME. Lose the volume without the gitignored
identity dirs going with it — `docker volume rm`, `compose down -v`, a Docker
Desktop cleanup, Part 3's negative test — and the two disagree: setup.sh
skipped the stash and the gateway commissioned anyway, inventing a `temp`
identity and rewriting the TRACKED `security-properties` to point at it (the
APIToken permissions get stripped on the way). Reproduced on the pristine repo
with plain `scripts/setup.sh`: exit 0, "Setup complete!", scan HTTP 200 — and a
tree holding `systemAuthProfile: temp`. Silent, because the API-permission
graft repairs the symptom.

Why it matters: `git add -A` then commits that policy, and deploy.yml ships it
to gateways whose wipe step deletes any `temp` dirs — a policy naming a profile
that does not exist, which is the course-day lockout shape.

Now (labs 04, 05 and 06 all carry this):
- `local_will_commission()` asks the data volume (does it hold an internal db?),
  and an answer it cannot get counts as "commissioned" so a live gateway's
  identity is never deleted on a guess.
- When it will commission, the stale identity dirs are removed first, so
  commissioning writes a clean `default`.
- `heal_temp_identity()` runs on every setup: a `temp*` profile is restored
  from git, the temp dirs deleted, the gateway restarted.
- `teardown.sh --volumes` removes `temp*` too; `.gitignore` covers `temp*`.
- `validate.sh` + `ci.yml` fail if `security-properties` names a `temp*`
  profile — the commit path, caught before a deploy.

Verified per lab, four cases each: fresh setup, break-with-bare-compose-up →
heal, the original volume-only-wipe case, and a headless admin login after each
(`"success":true`).

### A3. Module-manifest behaviour (all verified live — read before editing
### Part 3)

**Part 3 design (env-var derivation) — reverified live 2026-07-14 on a fresh
volume, local gateway, Ignition 8.3.8.** The whole point of Part 3 is that the
student never types the fingerprint/hash: the gateway computes them.

- **A `.modl` in the external-modules folder is NOT auto-installed on its own.**
  Dropping the file and listing the module in `GATEWAY_MODULES_ENABLED` is not
  enough — with no `modules.json` entry pointing at the file, the module simply
  does not load (verified: charts absent from the manifest → never starts,
  `/res/embr-charts/` → 404, gateway boots clean). The manifest entry
  (`filename` + `onStartup`) is what installs it. (This corrects the earlier
  note that claimed the gateway auto-registers any `.modl` it finds.)
- **The gateway DERIVES `certFingerprint` + `licenseAgreementHash` and writes
  them back into the mounted `modules.json`.** Give it a minimal entry
  (`filename` + `onStartup: "enabled"`, no fingerprint/hash) for a module that
  is listed in `ACCEPT_MODULE_LICENSES` + `ACCEPT_MODULE_CERTS`, boot once, and
  the file gains the two computed fields. Verified values: charts
  `e5a3cf3f06627c175b68b0122ac8f2c3f9c992e2` / `3266212556`; periscope same
  cert fingerprint / `101444854`. This is the derivation students commit.
- **Seed state for the three spares (Periscope, Charts, TimescaleDB
  Historian), since 2026-07-22: ABSENT from `services/modules.json` AND from
  all three module env vars in the compose anchor.** On a fresh boot the
  gateway comes up clean and RUNNING with none of them loaded
  (`/res/embr-periscope/` → 404), and the platform-modules page does not
  list them — that observation is now the assignment's step 1. Part 3 is a
  two-file edit: add the three ids to `GATEWAY_MODULES_ENABLED` +
  `ACCEPT_MODULE_LICENSES` + `ACCEPT_MODULE_CERTS` (the shared anchor, so
  `docker compose up -d` recreates ALL gateways with the new env — which is
  also why the later deploy-restart of test works), add the minimal manifest
  entries → boot → gateway derives and writes the two fields → commit both
  files.
- **`GATEWAY_MODULES_ENABLED` force-*enables* a listed module even when the
  manifest says `onStartup: "disabled"`** — the env list wins. That's why the
  spare is kept OUT of the seed manifest entirely rather than shipped
  `disabled`: a `disabled` entry would be overridden to enabled on the next boot
  anyway. A module ABSENT from `GATEWAY_MODULES_ENABLED` is force-disabled.
- **An env-enabled module without accepted terms parks the gateway at the
  commissioning screen** (`{"state":"RUNNING","details":"COMMISSIONING"}`,
  `needs_commissioning`, web UI → welcome, scan API → 400) — on a FRESH volume
  too. This is the Part 3 negative test: drop the module from `ACCEPT_MODULE_*`
  and remove its derived fields, wipe the volume, boot → parks; restore both →
  un-parks.
- **Enablement is sticky**: once a gateway has run a module, flipping the
  manifest back to `disabled` does NOT unload it (the internal DB wins and
  rewrites the file). Removing acceptance DOES bite. To truly reset a
  gateway's module state, wipe its data volume and re-run `setup.sh`.
- **Verifying "actually Running", hands-free (no UI):** the module's mounted web
  resources are served only when it is Running — `curl -s -o /dev/null -w
  '%{http_code}' http://localhost:8088/res/embr-periscope/` returns **200**
  (Running), **302** (parked/commissioning), or **404** (not installed). Cross-
  check the wrapper log: `Starting up module 'com.mussonindustrial.embr.periscope'`
  with no matching `Shutting down` after it.
- **`StatusPing` says `"state":"RUNNING"` even while commissioning** (the
  detail field carries `"COMMISSIONING"`); a green health check does not
  mean the API is up. The deploy's scan step (HTTP 400) is what actually
  catches a parked gateway.

### A4. Smaller checks / still open

- **1B (LabSecrets provider) — VERIFIED via a real UI run (2026-07-13).**
  Two findings:
  - The UI writes the new provider into the **active deployment mode's
    collection** — `resources/local-development/ignition/secret-provider/LabSecrets/` on
    the local gateway (booted in local-development mode) — NOT into `core` (IA's platform deep-dive
    claims UI-created resources land in Core; not true here). A provider left in the local-development collection resolves fine locally but never deploys (test inherits
    `external → core → test`), so develop faults on a missing provider while
    local stays green. Slide 1B step 4 + lab.md now teach the check-and-move
    (`mv services/config/resources/{local-development,core}/ignition/secret-provider` +
    rescan — verified live: connections stay Valid after the move).
  - The file shape is clean to commit (names + paths, no secret material):

    ```json
    {
      "profile": { "type": "file" },
      "settings": {
        "files": {
          "POSTGRES_PASSWORD": { "description": "", "filePath": "/run/secrets/postgres_password", "fileType": "CLEARTEXT" },
          "REPORTING_PASSWORD": { "description": "", "filePath": "/run/secrets/reporting_password", "fileType": "CLEARTEXT" }
        }
      }
    }
    ```
- The bundled runner auto-registers from the `repo`-scope PAT in
  `RUNNER_GITHUB_PAT` (reused from Lab 04), so a plain `docker compose up -d`
  re-registers fine. If jobs queue forever, check the PAT isn't the
  placeholder (a 401 in `docker compose logs github-runner`) and
  `docker compose up -d --force-recreate github-runner`.
- GitHub Actions had transient job-setup failures during the rehearsal
  ("Bad Gateway" / "Failed to resolve action download info") —
  `gh run rerun <id> --failed` cleared them; don't chase ghosts.
- Students with an EXISTING lab04-era database volume: the lab assumes a
  fresh `lab06` compose project (fresh volumes) — `db-init` only runs on
  first init. Say it out loud at the start. The compose file now pins
  `name: cicd-lab06`, so a second clone of THIS lab (a fork sitting next to the
  course repo) no longer silently inherits the other clone's containers and
  timescaledb volume — but a lab04 volume is still a different stack.
- FIXED 2026-07-30: 1A/1C used to say "before compose up", which this repo's
  deploy.yml has no step for. Both now point at the marked insertion comment
  (`# Part 1C`), i.e. before the pre-wired "Ship secret files" step.
- RAM: 3 gateways + DB + runner ≈ 8 GB — unchanged from Lab 04.

## B. Answer key (sketch)

### Warm-up
The pipeline ships **config** (names, references, targets). It can never
carry: the **password values** (must not be in Git; embedded ciphertexts
don't decrypt on another gateway) and anything **per-environment that only
exists in core** (the Reports connection's database target).

### Part 1
- 1A: top-level `secrets:` block backed by `./secrets/*.txt`,
  `POSTGRES_PASSWORD_FILE` + `REPORTING_PASSWORD_FILE` on the DB service,
  and **both** secrets attached to **both** services — `gateway-local-development`
  *and* `timescaledb`. Attaching only `postgres_password` to the DB service (what
  the slide used to show) leaves `REPORTING_PASSWORD_FILE` pointing at a file
  that isn't mounted: invisible on an existing volume, but on the next fresh
  volume `db-init/` aborts on `REPORTING_PASSWORD (or _FILE) must be set` and
  Postgres never initializes. `docker inspect` now clean.
- 1B: file-type provider `LabSecrets` with `POSTGRES_PASSWORD` →
  `/run/secrets/postgres_password`, `REPORTING_PASSWORD` →
  `/run/secrets/reporting_password`; both connections re-pointed to
  `{"type": "Referenced", ...}`. Grep proof: values appear nowhere under
  `services/config/`.
- 1C: test override at
  `services/config/resources/test/ignition/database-connection/TimescaleDB_Reports/config.json`
  (`connectURL` → `...5432/ignition_test`, copy the TimescaleDB test override
  incl. its `resource.json`) plus the `production` twin (`connectURL` →
  `...5432/ignition_production`); GitHub env secrets `POSTGRES_PASSWORD` +
  `REPORTING_PASSWORD` on BOTH `lab-gateway-test` and `lab-gateway-production`;
  Materialize step:

  ```yaml
  - name: Materialize secret files
    env:
      POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
      REPORTING_PASSWORD: ${{ secrets.REPORTING_PASSWORD }}
    run: |
      umask 177
      mkdir -p secrets
      printf '%s' "$POSTGRES_PASSWORD" > secrets/postgres_password.txt
      printf '%s' "$REPORTING_PASSWORD" > secrets/reporting_password.txt
  ```
- 1D: branch `feature/fix-test-db-connections` → PR (ci.yml: validate +
  secret scan) → merge → deploy.yml (materialize → ship secrets → ship
  files → scan → verify) → both Valid, Reports on `ignition_test` → release
  with a tag (`git tag v1.0.0 && git push origin v1.0.0` — release.yml is a
  thin caller that runs deploy.yml via workflow_call with
  `target: production`, so the student-added 1C/2B steps ship too; forks may
  carry stale `v*` tags, next free number is fine) → both Valid on
  production, Reports on `ignition_production`. Manual dispatch of deploy.yml
  (`target: production`) remains the rollback / re-run button.

### Part 2
- 2A: `0002_add_downtime_log.up.sql` / `.down.sql` (CREATE TABLE
  downtime_log / DROP TABLE downtime_log); `scripts/migrate.sh up`; ledger
  at version 2, idempotent re-run. The editing-an-applied-file trap: tool
  stays silent; rule lives in `db-migration/MIGRATIONS.md`.
- 2B: at the marked insertion point (before the ship steps, NOT
  continue-on-error), deriving the database from the deploy target so a
  `target: production` promotion migrates `ignition_production`:

  ```yaml
  - name: Migrate database
    run: |
      case "$DEPLOY_TARGET" in
        production) db=ignition_production ;;
        *)    db=ignition_test ;;
      esac
      ./scripts/migrate.sh up --database "$db"
  ```
  Debrief hook: the production repo runs migrations after the scan with
  continueOnError — screens referencing a table that doesn't exist yet, and
  a red step nobody reads.

### Part 3
Add the minimal `com.mussonindustrial.embr.periscope` entry (`filename` +
`onStartup: "enabled"`) — the spare ships ABSENT from `services/modules.json`.
Boot once: the gateway derives `certFingerprint` + `licenseAgreementHash`
(`…/101444854`) and writes them into the file; commit those. Verify Running
via `docker logs … | grep "Starting up module"` or Config → Modules (the
students' lab.md no longer uses the `/res/…` curl check — dropped by design;
the curl mechanics in A3 stay valid for instructor-side debugging). Negative
test: drop periscope from
`ACCEPT_MODULE_*` and remove the derived fields → a fresh boot parks the
gateway at commissioning — license acceptance is config, not memory. (See A3
for the full verified behaviour.)

### Stretch
- S1: internal provider = ciphertext in gateway config → faults after deploy
  to test (different keys). Escape hatch: `ignition-secrets-tool.sh`, shared
  root key + KEK — the keys become the secret.
- S2: expand-contract: 0003 add+backfill, screen switch, 0004 drop.
- S3: gitleaks job with `fetch-depth: 0` (the scanner needs history, not the
  tip).
- S4: library JAR through the pipeline (ported from the lab 07 Stephan
  challenge). `jar-files/jar/commons-csv-1.14.1.jar` is committed —
  **commons-csv, NOT commons-lang3**: verified live 2026-07-22 that the
  8.3.8 image bundles `commons-lang3-3.11.jar` AND `commons-text-1.10.0.jar`
  (plus guava, commons-io/codec/collections4/math3/…) under
  `lib/core/common/`, on the gateway scripting classpath. With the old
  commons-lang3 JAR the "binding errors first" premise was FALSE — the
  import resolved from the bundled 3.11 (proven via a temp WebDev endpoint:
  CodeSource → `lib/core/common/commons-lang3-3.11.jar`). commons-csv is
  not bundled: import genuinely fails (`No module named csv`) until the JAR
  lands, then resolves from `lib/core/gateway/commons-csv-1.14.1.jar` —
  both directions verified E2E, including the local file-volume mount
  (single-file bind mount + `docker compose up -d`, JAR on classpath after
  the boot).
  Student flow: (1) Text Field + Label, label bound to the field's
  `props.text` with a script transform doing `CSVFormat.DEFAULT.parse(...)`
  → binding errors while the class is missing (Perspective bindings
  evaluate on the GATEWAY, so it's the gateway classpath that matters, not
  the Designer); (2) fix local with a single-file bind mount into
  `/usr/local/bin/ignition/lib/core/gateway/` + `docker compose up -d`
  (classpath is read at boot); (3) paste the ready-made "Ship library JARs"
  step from exercises/lab.md at the marked S4 HERE comment in deploy.yml
  (md5-compare per JAR, restart only when changed) AND `"jar-files/**"` in
  `push.paths`; (4) PR → merge → verify the CSV parse on test. Gotchas:
  forgetting the paths entry means a JAR-only PR never deploys; the local
  bind mount only exists where the working tree does — test/production get
  the bytes from the pipeline, which is the point.
