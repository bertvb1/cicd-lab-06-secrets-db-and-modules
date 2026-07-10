# Secrets management for an Ignition pipeline — the approach

Reference reading for Lab 06. This is the "why + how" behind Part 1 of the
assignment. It describes the target state; some repo pieces are still marked
TODO. The Wilms production repo (wilms-ignition-repo) is the reference
implementation for the full pattern.

## 1. Three kinds of configuration

Every value in your repo is one of three kinds. Sorting them is 80% of secrets
management:

| Kind | Examples | Where it lives |
|---|---|---|
| **Public** | port numbers, module lists, project names, timeouts | committed, plain, in `docker-compose.yaml` / config files |
| **Per-environment** | gateway URLs, database *names*, container names | committed defaults + overridable env vars / GitHub environment *variables* |
| **Secret** | passwords, API keys, PATs, private keys, keystores | **never committed** — `.env`, Docker secrets, secret providers, GitHub *secrets* |

The failure mode is always the same: a secret masquerading as per-environment
config and getting committed "just to make it work".

## 2. The iron rules

1. **A pushed secret is a burned secret.** Git history is immutable and cloned
   everywhere. Deleting the line in a new commit changes nothing — the value is
   still one `git log -p` away. The response is always **rotate first**, scrub
   history second (`git filter-repo` / BFG), and scrubbing is best-effort on a
   shared remote.
2. **`.env` is gitignored, `.env.example` is committed.** The labs have used
   this convention since Lab 02: the example documents every variable with a
   safe placeholder; the real file never leaves your machine.
3. **CI never prints secrets.** GitHub Actions masks registered secrets in logs
   (`***`), but masking is a seatbelt, not a licence — don't `echo`, don't
   `set -x` around them, don't write them to artifacts.
4. **Least scope, short life.** Per-gateway API keys instead of one master key;
   PATs with `repo` scope only; GitHub *environment* secrets
   (`lab-gateway-dev` / `lab-gateway-prod`) instead of repo-wide ones.

## 3. The ladder

From "works on my machine" to "portable across gateways". Each rung fixes the
previous rung's leak.

### Rung 0 — hardcoded (never)
Plaintext in `docker-compose.yaml` or a committed config file. Leaks into: Git
history, every clone, every fork.

### Rung 1 — environment variables via `.env` + Compose interpolation
What labs 02–06 do: `POSTGRES_PASSWORD: "${POSTGRES_PASSWORD:-ignition}"` with
the real value in a gitignored `.env`. Good: out of Git. Still leaks into:
`docker inspect`, `docker compose config`, the container's process environment
(visible to anything that can read `/proc/1/environ` or trigger a debug dump).

### Rung 2 — file-based secrets (files under `/run/secrets/`) — the best way we know
A top-level `secrets:` block in Compose, backed by files in the gitignored
`secrets/` directory, mounted read-only at `/run/secrets/<name>` inside the
container. Good: not in `docker inspect`, not in the process env. Works with
plain `docker compose` — no Swarm needed for file-backed secrets — and the same
file-at-a-known-path idea carries unchanged to Kubernetes secret volumes and to
Ignition's file-type secret provider. That portability is why we treat this as
the default production answer.

Many official images (Postgres included) accept a `_FILE` suffix on their env
vars (e.g. `POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password`) so the
value is read from the mounted file.

Who fills the files: locally, committed dummy values (Wilms commits a
`secrets/` folder of non-sensitive local-dev values so a fresh clone just
works); on deployed environments, the infra team or the deploy workflow — a
`deploy.yml` step can materialize GitHub secrets into these files
(`umask 177` + `printf '%s'`) right before `compose up`.

### Rung 3 — Ignition 8.3 secret providers (the native answer)
Ignition 8.3 added first-class **secrets management**: gateway config no longer
needs to store secret values inline. Two flavours matter for CI/CD:

- **Embedded secrets** — the value is encrypted by *this* gateway and stored in
  its config. Fine for a single hand-managed gateway, but the ciphertext is
  encrypted against that gateway's keys, so a committed ciphertext only
  decrypts on the gateway that produced it — on a fresh container it's a broken
  reference.
- **Referenced secrets** — the config stores a *reference*; the value itself
  comes from a secret provider at runtime, e.g. a **file** (which is exactly
  what a file-based secret is: a file under `/run/secrets/`). Real serialized
  shape, from the Wilms repo:

  ```json
  "password": {
    "type": "Referenced",
    "data": { "providerName": "WilmsSecrets", "secretName": "MSSQL_PASSWORD" }
  }
  ```

**Why referenced wins for a pipeline:** the same committed gateway config works
on local, dev and prod, because each environment injects its *own* value under
the same secret name. Config stays in Git; values stay out. This is the same
pattern as GitHub environments (same workflow, different `IGNITION_API_KEY` per
environment) — one mental model everywhere.

### The alternative: committed ciphertexts with shared keys
Ignition 8.3 ships a **secrets-management key CLI tool**
(`ignition-secrets-tool.sh` / `.bat`) that manages the encryption keys behind
embedded secrets — a root key and key-encryption keys stored as JSON files
under `data/config/ignition/keys/` (`root.json`, `kek.json`). If you distribute
the *same* keys to your gateways (redundant pairs already work this way),
committed ciphertext decrypts everywhere, which makes "commit the embedded
ciphertext" a defensible alternative to file-based secrets. The trade: the key
files become the secret — infra distributes them out-of-band, and they must
never be committed. Docs:
https://docs.inductiveautomation.com/docs/8.3/platform/security/secrets-management/secrets-management-key-cli-tool

## 4. What should NEVER be committed

- `.env` (any real one; `.env.example` with placeholders is fine)
- `secrets/` contents (only `*.example` files are tracked)
- GitHub PATs (`ghp_…`), runner registration tokens
- Ignition gateway API keys
- Gateway backups (`.gwbk`) taken from real systems — they contain users, DB
  connections and keystores
- Keystores / TLS private keys (`ssl.pfx`, `metro-keystore`, `*.p12`, `*.pem` private halves)
  <!-- [VERIFY] exact 8.3 on-disk names/paths for the gateway keystores -->
- The gateway's secrets-management **key files**
  (`data/config/ignition/keys/root.json`, `kek.json`) — if you use the
  shared-keys/ciphertext approach, these ARE the secret
- Exported `config.json` containing **embedded** secret ciphertext — *unless*
  you deliberately run the shared-keys approach above and treat the keys as the
  secret; otherwise use referenced secrets so the question never comes up

Enforcement: the repo's `scripts/validate.sh` should run a secret scanner
(e.g. **gitleaks**) locally and in `ci.yml`, so a leaked key fails the PR
before a human ever reviews it. <!-- TODO(infra): wire gitleaks into validate.sh + ci.yml -->

## 5. How this maps onto the lab's pipeline

| Place | Mechanism |
|---|---|
| Your laptop | `.env` (gitignored) + `secrets/` files |
| Compose stack | interpolation for non-secrets; Docker secrets for credentials |
| Ignition gateways | referenced secrets from a provider fed by env/file |
| GitHub Actions | environment-scoped secrets (`lab-gateway-dev`, `lab-gateway-prod`); masked in logs |
| The repo | `.env.example`, `secrets/*.example`, secret scanner in CI |
