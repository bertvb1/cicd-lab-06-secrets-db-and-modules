# Lab 06 — instructor key & pre-course verification list

Two sections: what MUST be verified/re-seeded on a live stack before the
course runs, and the answer key for the parts.

## A. Seeding mechanics (verified live on 8.3.6) & what's left to check

### A1. How the warm-up's broken state works — VERIFIED

Empirical findings from a live run (2026-07-13, Ignition 8.3.6):

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

The runnable answer key lives on the **`rehearsal/lab-solutions`** branch
(PR #2, draft, never to be merged): the Materialize + Migrate steps at their
insertion points, the `TimescaleDB_Reports` test override, the `0002` pair,
and the enabled Periscope entry. To re-verify any flow, dispatch `deploy.yml`
from that branch with `target=test`.

### A3. Module-manifest behaviour (all verified live — read before editing
### Part 3)

**Part 3 design (env-var derivation) — reverified live 2026-07-14 on a fresh
volume, local gateway, Ignition 8.3.6.** The whole point of Part 3 is that the
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
- **Seed state for the spare (Periscope): in all three env vars, but ABSENT
  from `services/modules.json`.** So on a fresh boot the gateway comes up clean
  and RUNNING with periscope *not* loaded (`/res/embr-periscope/` → 404). Part 3
  is a single-file edit: add the minimal manifest entry → boot → gateway derives
  and writes the two fields → commit. (Charts stays fully specified + enabled in
  the seed as the worked teaching example on slide 15.)
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
  first init. Say it out loud at the start.
- Slides 1A/1C say "before compose up" — this repo's deploy.yml has no
  compose up; the insertion-point comments say "before the ship steps".
  Align the slides or the workflow, whichever you prefer.
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
  both secrets attached to `gateway-local-development`. `docker inspect` now clean.
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
  files → scan → verify) → both Valid, Reports on `ignition_test` → promote
  with a manual dispatch (`target: production`) → both Valid on production, Reports on
  `ignition_production`.

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
with `curl .../res/embr-periscope/` → 200. Negative test: drop periscope from
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
