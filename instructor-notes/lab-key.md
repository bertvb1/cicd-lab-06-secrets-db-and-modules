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
  passphrase `lab06-root-key-pass` passed to the loc gateway via
  `IGNITION_ROOT_KEY_PASSWORD` in docker-compose.yaml). The keys are
  deliberately COMMITTED (dummy values) so every student's local gateway
  decrypts the seeded ciphertexts, and excluded from the deploy payload via
  `.deployignore`, so dev/prod cannot.
- A gateway with custom keys still decrypts default-key ciphertexts (the
  MQTT / OPC UA seeds keep working everywhere). A gateway WITHOUT the custom
  keys fails on custom-KEK ciphertexts with `Unable to decrypt ciphertext`.
- Verified end state: local gateway — both connections + historian Valid
  (live sessions for `ignition` and `reporting`); dev gateway after a
  simulated deploy — `TimescaleDB` and `TimescaleDB_Reports` both Faulted
  with `Unable to decrypt ciphertext` (the historian provider on dev faults
  the same way; that's expected seed noise, mention it if someone spots it).
- All custom-KEK ciphertexts (TimescaleDB core/loc/dev/prd, Reports core,
  historian core/loc) encrypt the passwords that `db-init` actually sets:
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

- **Warm-up**: `deploy.yml` green to dev (push + dispatch) and prod
  (dispatch, `target=prod`); both gateways' connections Faulted with
  `Unable to decrypt ciphertext`; local Valid.
- **1C**: Materialize + the pre-wired "Ship secret files" step land
  `postgres_password` / `reporting_password` at `/run/secrets/` with mode
  600. (Connections-go-Valid still depends on 1B's provider, which is UI
  work — see A4.)
- **2B**: `scripts/migrate.sh up --database ignition_dev` runs from inside
  the containerized runner; dev's `schema_migrations` reached version 2
  before the ship steps.
- **Part 3**: manifest change → detected → gateway restart →
  `Starting up module 'com.mussonindustrial.embr.periscope'` → Running.
- **ci.yml**: all three jobs (Lint incl. ign-lint, Validate, Secret scan)
  green on PR #2.

The runnable answer key lives on the **`rehearsal/lab-solutions`** branch
(PR #2, draft, never to be merged): the Materialize + Migrate steps at their
insertion points, the `TimescaleDB_Reports` dev override, the `0002` pair,
and the enabled Periscope entry. To re-verify any flow, dispatch `deploy.yml`
from that branch with `target=dev`.

### A3. Module-manifest behaviour (all verified live — read before editing
### Part 3)

- **`GATEWAY_MODULES_ENABLED` force-disables absent modules on every boot**,
  silently, regardless of modules.json. The spare module must stay in that
  compose list; what Part 3 toggles is `onStartup` in the manifest.
- **An env-enabled module without accepted license terms parks the gateway
  at the commissioning screen** (`needs_commissioning`, web UI → welcome,
  scan API → 400) — on a FRESH volume too. That's why the seed ships
  Periscope's `certFingerprint` + `licenseAgreementHash` with
  `onStartup: "disabled"`. It is also exactly what the Part 3 negative test
  demonstrates: remove the hash, redeploy, and dev parks until the
  acceptance is restored (a redeploy with the hash back un-parks it).
- **Enablement is sticky**: once a gateway has run a module, flipping the
  manifest back to `disabled` does NOT unload it (the internal DB wins and
  rewrites the file). Removing acceptance DOES bite. To truly reset a
  gateway's module state, wipe its data volume and re-run `setup.sh`.
- The gateway auto-registers any `.modl` it finds in the external-modules
  folder into its manifest, and rewrites the mounted `modules.json` at will
  — which is why dev/prod get their own copies under `gateways/<gw>/`.
- **`StatusPing` says `"state":"RUNNING"` even while commissioning** (the
  detail field carries `"COMMISSIONING"`); a green health check does not
  mean the API is up. The deploy's scan step (HTTP 400) is what actually
  catches a parked gateway.

### A4. Smaller checks / still open

- **1B (LabSecrets provider) — VERIFIED via a real UI run (2026-07-13).**
  Two findings:
  - The UI writes the new provider into the **active deployment mode's
    collection** — `resources/loc/ignition/secret-provider/LabSecrets/` on
    the loc-mode local gateway — NOT into `core` (IA's platform deep-dive
    claims UI-created resources land in Core; not true here). A loc-collection
    provider resolves fine locally but never deploys (dev inherits
    `external → core → dev`), so develop faults on a missing provider while
    local stays green. Slide 1B step 4 + lab.md now teach the check-and-move
    (`mv services/config/resources/{loc,core}/ignition/secret-provider` +
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
- The bundled runner loses its registration if its container is recreated
  without a fresh token (plain `docker compose up -d` after a config
  change): jobs queue forever. Re-run `scripts/setup.sh` — it mints a token
  and re-registers.
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
  both secrets attached to `gateway-loc`. `docker inspect` now clean.
- 1B: file-type provider `LabSecrets` with `POSTGRES_PASSWORD` →
  `/run/secrets/postgres_password`, `REPORTING_PASSWORD` →
  `/run/secrets/reporting_password`; both connections re-pointed to
  `{"type": "Referenced", ...}`. Grep proof: values appear nowhere under
  `services/config/`.
- 1C: dev override at
  `services/config/resources/dev/ignition/database-connection/TimescaleDB_Reports/config.json`
  (`connectURL` → `...5432/ignition_dev`, copy the TimescaleDB dev override
  incl. its `resource.json`); GitHub env secrets `POSTGRES_PASSWORD` +
  `REPORTING_PASSWORD` on `lab-gateway-dev`; Materialize step:

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
- 1D: branch `feature/fix-dev-db-connections` → PR (ci.yml: validate +
  secret scan) → merge → deploy.yml (materialize → ship secrets → ship
  files → scan → verify) → both Valid, Reports on `ignition_dev`.

### Part 2
- 2A: `0002_add_downtime_log.up.sql` / `.down.sql` (CREATE TABLE
  downtime_log / DROP TABLE downtime_log); `scripts/migrate.sh up`; ledger
  at version 2, idempotent re-run. The editing-an-applied-file trap: tool
  stays silent; rule lives in `db-migration/MIGRATIONS.md`.
- 2B: at the marked insertion point (before the ship steps, NOT
  continue-on-error):

  ```yaml
  - name: Migrate database
    run: scripts/migrate.sh up --database ignition_dev
  ```
  Debrief hook: the production repo runs migrations after the scan with
  continueOnError — screens referencing a table that doesn't exist yet, and
  a red step nobody reads.

### Part 3
Entry for `com.mussonindustrial.embr.periscope` (values in
`exercises/lab.md`). Negative test: without `licenseAgreementHash` a fresh
boot leaves the module unloaded/quarantined — license acceptance is config,
not memory.

### Stretch
- S1: internal provider = ciphertext in gateway config → faults after deploy
  to dev (different keys). Escape hatch: `ignition-secrets-tool.sh`, shared
  root key + KEK — the keys become the secret.
- S2: expand-contract: 0003 add+backfill, screen switch, 0004 drop.
- S3: gitleaks job with `fetch-depth: 0` (the scanner needs history, not the
  tip).
