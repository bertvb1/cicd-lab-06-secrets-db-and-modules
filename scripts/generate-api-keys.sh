#!/usr/bin/env bash
# generate-api-keys.sh — provision one Ignition scan-API token PER GATEWAY,
# without ever putting a secret in git.
#
# For each gateway (local / test / production) this script:
#   1. ensures .env has a real IGNITION_API_KEY_<GW> — if the line is empty,
#      missing, or a placeholder, it generates `cicd:<base64url(32 random
#      bytes)>` and writes it into .env;
#   2. writes the matching api-token resource — the gateway stores only the
#      SHA-256 hash of the secret — into that gateway's config tree:
#        local -> services/config/resources/core/ignition/api-token/cicd/
#        test   -> gateways/test/config/resources/core/ignition/api-token/cicd/
#        production  -> gateways/production/config/resources/core/ignition/api-token/cicd/
#      All three paths are gitignored, so the token never enters a commit.
#      A fresh core/ tree also gets the config-mode.json collection manifest
#      (REQUIRED: a non-empty collection dir without it FAULTs first boot).
#
# Idempotent: an existing key in .env is kept, and a resource file is only
# (re)written when its hash does not match the key. Because the hash is
# derived from the key, .env is the single source of truth — a wiped config
# tree (e.g. teardown.sh --volumes) is fully restored on the next run, and
# deleting .env as well simply mints brand-new keys.
#
# The gateway only READS token resources at boot. setup.sh runs this before
# `docker compose up` so first boot loads them, and self-heals a 401 (token
# written while the gateway was already running) by restarting that gateway.
#
# Usage:
#   scripts/generate-api-keys.sh          # normally invoked by setup.sh

set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v python3 >/dev/null || { echo -e "${RED}python3 is required${NC}" >&2; exit 1; }

if [ ! -f "$PROJECT_ROOT/.env" ]; then
  echo -e "${RED}No .env found — run scripts/setup.sh (it creates .env first).${NC}" >&2
  exit 1
fi

python3 - "$PROJECT_ROOT" <<'PYEOF'
import base64, hashlib, json, os, re, secrets, shutil, sys, time, uuid

root = sys.argv[1]
env_path = os.path.join(root, ".env")
with open(env_path) as f:
    env_text = f.read()

TOKEN_NAME = "cicd"
GATEWAYS = {          # env-var suffix -> that gateway's config bind mount
    "LOCAL": "services/config",
    "TEST":   "gateways/test/config",
    "PRODUCTION":  "gateways/production/config",
}
MANIFEST_SRC = os.path.join(root, "services/config/resources/core/config-mode.json")


def is_placeholder(value):
    return not value or "replace-me" in value or ":" not in value


def token_hash(key):
    # Ignition 8.3 api-token: hash = base64url_nopad(sha256(secret bytes)),
    # where the key is "<name>:<base64url_nopad(secret bytes)>".
    secret_b64 = key.split(":", 1)[1]
    raw = base64.urlsafe_b64decode(secret_b64 + "=" * (-len(secret_b64) % 4))
    return base64.urlsafe_b64encode(hashlib.sha256(raw).digest()).rstrip(b"=").decode()


def token_config(thash):
    # Same profile shape as the token the gateway UI creates: the APIToken
    # levels are what the security-properties scan permissions check for.
    api_children = [{"children": [], "name": n} for n in ("Access", "Read", "Write")]
    return {
        "profile": {
            "secureChannelRequired": False,
            "securityLevels": [{
                "children": [
                    {"children": [{"children": [], "name": "Administrator"}],
                     "name": "Roles"},
                    {"children": api_children, "name": "APIToken"},
                ],
                "description": "Represents a user who has been authenticated by the system.",
                "name": "Authenticated",
            }],
            "timestamp": int(time.time() * 1000),
            "type": "basic-token",
        },
        "settings": {"tokenHash": thash},
    }


env_changed = False
for gw, config_dir in GATEWAYS.items():
    var = f"IGNITION_API_KEY_{gw}"
    m = re.search(rf"^[ \t]*{var}=(.*)$", env_text, re.M)
    value = m.group(1).strip().strip("\"'") if m else ""

    if is_placeholder(value):
        secret = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
        value = f"{TOKEN_NAME}:{secret}"
        line = f"{var}={value}"
        if m:
            env_text = env_text[:m.start()] + line + env_text[m.end():]
        else:
            env_text = env_text + ("" if env_text.endswith("\n") else "\n") + line + "\n"
        env_changed = True
        print(f"  {gw.lower()}: generated a new API key into .env ({var})")

    name = value.split(":", 1)[0]
    thash = token_hash(value)
    res_dir = os.path.join(root, config_dir, "resources/core/ignition/api-token", name)
    config_path = os.path.join(res_dir, "config.json")

    current = None
    if os.path.isfile(config_path):
        try:
            with open(config_path) as f:
                current = json.load(f)["settings"]["tokenHash"]
        except (ValueError, KeyError):
            pass
    if current == thash:
        continue

    core_dir = os.path.join(root, config_dir, "resources/core")
    os.makedirs(res_dir, exist_ok=True)
    manifest = os.path.join(core_dir, "config-mode.json")
    if not os.path.isfile(manifest):
        shutil.copyfile(MANIFEST_SRC, manifest)
    with open(config_path, "w") as f:
        json.dump(token_config(thash), f, indent=2)
        f.write("\n")
    with open(os.path.join(res_dir, "resource.json"), "w") as f:
        json.dump({
            "scope": "A", "description": "", "version": 1,
            "restricted": False, "overridable": True,
            "files": ["config.json"],
            "attributes": {"uuid": str(uuid.uuid4()), "enabled": True},
        }, f, indent=2)
        f.write("\n")
    print(f"  {gw.lower()}: wrote api-token resource -> {config_dir}/resources/core/ignition/api-token/{name}/")

if env_changed:
    with open(env_path, "w") as f:
        f.write(env_text)
PYEOF
