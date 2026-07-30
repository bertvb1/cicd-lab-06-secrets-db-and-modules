#!/bin/bash
# One-shot setup for the lab 04 stack:
#   - sanity-checks the host (docker compose v2, curl, WSL quirks)
#   - installs the repo's git hooks (skip-worktree for the machine-local
#     Ignition config file) and a diff driver that hides volatile resource.json
#     metadata; volatile-only churn is undone with
#     scripts/clean-ignition-resource-churn.sh
#   - ensures .env is in place
#   - generates a unique API key per gateway into .env and writes the
#     hash-only token resource into each gateway's config tree
#     (scripts/generate-api-keys.sh — nothing key-related is committed)
#   - brings up the stack (three Ignition gateways + shared TimescaleDB)
#   - waits for ALL THREE gateways to become RUNNING
#   - triggers an initial projects + config scan against the LOCAL gateway.
#     Test and production start empty by design — they get populated by the deploy
#     and release workflows.
#
# Re-run safely — every step is idempotent.
#
# Env knobs:
#   CI=1                            run non-interactively (never prompt/sudo)
#   LAB_SKIP_PREFLIGHT=1            skip the host permission checks entirely
#   LAB_ALLOW_DRVFS=1               allow running from /mnt/c (not recommended)
#   LAB_ASSUME_YES=1                auto-answer preflight prompts with yes
#   NO_COLOR=1                      disable ANSI colors

set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=preflight.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preflight.sh"
cd "$PROJECT_ROOT"

# ---- Host preflight (WSL/permissions) ------------------------------------
# Verifies the repo is not on /mnt/c, refuses a sudo'd run, reclaims any
# root-owned leftovers, and exports LAB_GID for docker-compose.yaml.
lab_preflight

# ---- prerequisites --------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo -e "${RED}Error: '$1' is required but not installed.${NC}" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl
require_cmd git
require_cmd python3

if ! docker compose version >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker Compose V2 plugin is required but not installed.${NC}"
    echo ""
    echo "You appear to have the standalone 'docker-compose' (V1), which is deprecated."
    echo ""
    echo "Install the Docker Compose V2 plugin:"
    echo "  - Docker Desktop (Windows/Mac): Update to the latest version"
    echo "  - Linux/WSL: sudo apt-get update && sudo apt-get install docker-compose-plugin"
    echo "  - Or see: https://docs.docker.com/compose/install/"
    exit 1
fi

echo -e "${GREEN}Mustry Academy — Lab 06 setup${NC}"
echo "================================"
echo ""
echo "This script initializes the development environment:"
echo "  - three Ignition 8.3 gateways:"
echo "      local  http://localhost:8088   (your working gateway, bind-mounted from the repo)"
echo "      test    http://localhost:8089   (populated by deploy.yml on push to main)"
echo "      production   http://localhost:8090   (populated by deploy.yml run with target=production)"
echo "  - one TimescaleDB on localhost:5432 hosting ignition_local_development / ignition_test / ignition_production"
echo ""


# ---- Git hooks ------------------------------------------------------------
install_git_hooks() {
    local repo_hooks_dir
    repo_hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)" || return 0
    local source_dir="$PROJECT_ROOT/scripts/git-hooks"
    [ -d "$source_dir" ] || return 0
    mkdir -p "$repo_hooks_dir"
    # Clones set up before post-merge/post-rewrite were dropped still have
    # symlinks to the deleted files; git errors on every merge/rebase until
    # they are removed.
    for stale in post-merge post-rewrite; do
        local link="$repo_hooks_dir/$stale"
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            rm -f "$link"
        fi
    done
    # post-checkout only. Git keeps the skip-worktree bit across merge, rebase,
    # amend, reset --hard and stash, so hooks on those events had nothing to do.
    # The bit is only lost when the file leaves the index and comes back, which
    # is a checkout.
    ln -sf "$source_dir/post-checkout" "$repo_hooks_dir/post-checkout"
    if [ -x "$source_dir/skip-worktree-ignition-resources" ]; then
        "$source_dir/skip-worktree-ignition-resources" || true
    fi
}

install_git_hooks

# ---- pre-commit framework ---------------------------------------------------
# Installs .git/hooks/pre-commit from .pre-commit-config.yaml. That config holds
# the linters CI runs AND the hook that reverts junk-only resource.json
# rewrites, so without this the churn cleaner never runs on its own and Ignition
# metadata can still reach a commit.
install_pre_commit_hooks() {
    if ! command -v pre-commit >/dev/null 2>&1; then
        echo -e "${YELLOW}pre-commit is not installed, so resource.json churn will NOT be${NC}"
        echo -e "${YELLOW}reverted automatically and the linters CI runs stay local-only:${NC}"
        echo "  pip install pre-commit && pre-commit install"
        echo ""
        return 0
    fi
    if pre-commit install >/dev/null 2>&1; then
        echo -e "${GREEN}pre-commit hooks installed (linters + resource.json churn cleaner).${NC}"
    else
        echo -e "${YELLOW}pre-commit is installed but 'pre-commit install' failed; run it by hand.${NC}"
    fi
    echo ""
}

install_pre_commit_hooks

# ---- Git diff driver --------------------------------------------------------
# .gitattributes routes resource.json through this textconv normalizer so
# volatile Designer metadata (timestamps, signatures) never shows up in diffs.
configure_git_diff_drivers() {
    git config diff.ignition-resource.textconv "$PROJECT_ROOT/scripts/git-diff/normalize-ignition-resource-json.py"
}

configure_git_diff_drivers

# ---- .env -----------------------------------------------------------------
ensure_env_file() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        return 0
    fi
    if [ ! -f "$PROJECT_ROOT/.env.example" ]; then
        echo -e "${RED}Error: neither .env nor .env.example found.${NC}" >&2
        exit 1
    fi
    echo -e "${YELLOW}.env not found — copying from .env.example.${NC}"
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    echo -e "${YELLOW}Edit .env to set gateway passwords; the IGNITION_API_KEY_* values${NC}"
    echo -e "${YELLOW}are generated automatically a few steps down.${NC}"
    echo ""
}

ensure_env_file
# Record LAB_GID in the fresh .env so a later manual `docker compose up -d`
# (fresh terminal, no export) keeps the gateway in your group. See preflight.sh.
pf_persist_lab_gid

# ---- Runner PAT check (registers the bundled github-runner) ----------------
# The github-runner container auto-registers against your fork using the
# GitHub Personal Access Token in RUNNER_GITHUB_PAT (see .env) — reuse the same
# `repo`-scope PAT you created in Lab 04. If it's still the placeholder, the
# runner container will restart-loop with a 401 in its logs; the gateways still
# come up fine, so this is only a heads-up.
runner_pat_reminder() {
    local pat repo_url
    pat="$(env_value RUNNER_GITHUB_PAT)"
    repo_url="$(env_value RUNNER_REPO_URL)"
    if [ -z "$pat" ] || printf '%s' "$pat" | grep -q 'replace-me' \
        || [ -z "$repo_url" ] || printf '%s' "$repo_url" | grep -q '<your-github-user>'; then
        echo -e "${YELLOW}Runner not configured yet — the lab06-runner container will restart-loop until you:${NC}"
        echo "  1. Point RUNNER_REPO_URL in .env at your fork."
        echo "  2. Set RUNNER_GITHUB_PAT in .env to your Lab 04 repo-scope PAT"
        echo "     (or make one at github.com/settings/tokens → classic → tick 'repo')."
        echo "  Then re-run scripts/setup.sh. The gateways work without this; only CI needs the runner."
        echo ""
    fi
}

runner_pat_reminder

# ---- Test/production gateway state dirs + per-gateway API keys --------------
# test and production bind-mount ./gateways/<gw>/{projects,config} (see
# docker-compose.yaml) so you can verify a deploy landed straight from the
# host: `ls gateways/test/projects`. Create the dirs before compose up, then
# generate each gateway's OWN API key into .env and write the matching
# hash-only api-token resource into its config tree BEFORE first boot: the
# scan API only accepts tokens the gateway has LOADED, and the deploy
# workflow cannot scan its own token in (chicken-and-egg — the scan call
# already needs it). Nothing key-related is committed — the token paths are
# gitignored and the deploy wipe spares them on the gateway. The 403 that
# commissioning's permission reset causes is repaired further down.
seed_gateway_state() {
    local gw
    for gw in test production; do
        mkdir -p "$PROJECT_ROOT/gateways/$gw/projects" "$PROJECT_ROOT/gateways/$gw/config"
        # Per-gateway module manifest (see docker-compose.yaml): seed it from
        # the repo's manifest so the first boot has one; from then on ONLY
        # deploy.yml updates it. Must exist before compose up, or Docker
        # turns the single-file bind mount into an empty directory.
        if [ ! -f "$PROJECT_ROOT/gateways/$gw/modules.json" ]; then
            cp "$PROJECT_ROOT/services/modules.json" "$PROJECT_ROOT/gateways/$gw/modules.json"
        fi
    done
    "$SCRIPT_DIR/generate-api-keys.sh"
    # Everything created above is born AFTER lab_preflight's chmod pass, which
    # "only touches dirs that exist" — so on a fresh clone these trees get the
    # student's umask (typically 022: no group write) and the test/production
    # gateways (uid 2003, writing via the student's group) FAULT on first boot
    # with AccessDeniedException. Re-apply the bind-mount permissions now that
    # the trees exist.
    pf_prepare_bind_mounts
}

seed_gateway_state

# ---- Stale-volume detection (identity/volume desync) -----------------------
# A gateway's internal identity (user-source/default, identity-provider/
# default) lives in its CONFIG TREE — bind mounts: local -> services/config,
# test/production -> gateways/<gw>/config — but the "already commissioned" marker
# lives in its data VOLUME. Docker Compose reuses volumes by project (folder)
# name, so a fresh clone sitting next to volumes from an earlier stack boots
# gateways that skip commissioning yet have no identity on disk: the web UI
# dies with "Identity provider not found: default". Detect that desync and
# recreate the affected gateway's container + volume so commissioning runs
# again on this boot.
compose_project_name() {
    docker compose config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true
}

reset_desynced_gateways() {
    local project vol gw identity_dir
    project="$(compose_project_name)"
    if [ -z "$project" ]; then
        project="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
    fi
    for gw in "${LAB_GATEWAYS[@]}"; do
        case "$gw" in
            local) identity_dir="$PROJECT_ROOT/services/config/resources/core/ignition/user-source/default"
                   svc="gateway-local-development" ;;
            *)     identity_dir="$PROJECT_ROOT/gateways/$gw/config/resources/core/ignition/user-source/default"
                   svc="gateway-$gw" ;;
        esac
        vol="${project}_gateway-${gw}-data"
        if [ ! -d "$identity_dir" ] && docker volume inspect "$vol" >/dev/null 2>&1; then
            echo -e "${YELLOW}$gw gateway: data volume '$vol' exists but its config tree has no internal identity${NC}"
            echo "  (fresh clone next to an old stack?) — recreating it so commissioning runs again."
            # Remove the compose container first, or 'docker volume rm' below
            # fails with "volume is in use". The compose service is
            # gateway-local-development/-test/-production, NOT ignition-<gw>.
            docker compose rm -sf "$svc" >/dev/null 2>&1 || true
            # Belt-and-suspenders: kill any other (orphaned) container still
            # holding the volume — e.g. a Created container from a half-run
            # setup that compose no longer tracks.
            for c in $(docker ps -aq --filter "volume=$vol"); do
                docker rm -f "$c" >/dev/null 2>&1 || true
            done
            docker volume rm "$vol" >/dev/null
        fi
    done
}

reset_desynced_gateways

# ---- Stash security-properties whenever the local gateway commissions -----
# Any boot where the LOCAL gateway commissions — its first, or any boot after
# its data volume went away — auto-commissioning has to guarantee an admin
# login exists. If it finds a security-properties file but
# no matching user source (the repo tracks the policy file; the per-gateway
# user-source/default is gitignored), it plays safe and creates a temp_N
# identity, then rewrites security-properties to point at it — permanent git
# noise AND an auth profile no other gateway has. If it finds NO
# security-properties, it creates the `default` user source + identity
# provider, exactly like test/production do. So: move the committed file aside for
# that boot, then put it back (it names systemAuthProfile=default, which
# now exists, and carries the APIToken scan permissions) and restart local.
SECPROPS_DIR="$PROJECT_ROOT/services/config/resources/core/ignition/security-properties"
SECPROPS_STASH=""
IDENTITY_DIR="$PROJECT_ROOT/services/config/resources/core/ignition"

# Will the LOCAL gateway commission on THIS boot? The gateway answers that from
# its DATA VOLUME (the internal config db), never from the config tree — so the
# config tree is the wrong thing to ask. Asking it ("does user-source/default
# exist?") is what used to make this decide "already commissioned" while the
# gateway commissioned anyway: any volume that disappears without the gitignored
# identity dirs going with it (`docker volume rm`, `compose down -v`, a Docker
# Desktop cleanup, Part 3's negative test) leaves the two disagreeing, and the
# result is a `temp` identity plus a rewritten security-properties. So ask the
# volume. An answer we cannot get counts as "already commissioned", which
# changes nothing — never delete a live gateway's identity on a guess.
local_will_commission() {
    local project vol probe
    project="$(compose_project_name)"
    [ -n "$project" ] || project="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
    vol="${project}_gateway-local-data"
    docker volume inspect "$vol" >/dev/null 2>&1 || return 0   # no volume → it commissions
    probe="$(docker run --rm -v "$vol:/d" alpine:3 sh -c \
        '[ -d /d/db ] && [ -n "$(ls -A /d/db 2>/dev/null)" ] && echo has-internal-db; echo probe-ran' \
        2>/dev/null || true)"
    case "$probe" in
        *has-internal-db*) return 1 ;;   # internal db present → already commissioned
        *probe-ran*)       return 0 ;;   # volume there but empty → it commissions
        *)                 return 1 ;;   # probe could not run → change nothing
    esac
}

stash_secprops_for_commissioning() {
    # If a previous interrupted run left the file stashed away, recover the
    # committed version from git before deciding anything.
    if [ ! -d "$SECPROPS_DIR" ]; then
        git -C "$PROJECT_ROOT" checkout -- "$SECPROPS_DIR" 2>/dev/null || true
    fi
    [ -d "$SECPROPS_DIR" ] || return 0    # nothing to stash
    local_will_commission || return 0     # gateway keeps the identity it has
    # Commissioning is about to run, so any identity still on disk belongs to
    # the data volume that went away. Leaving it there is exactly what makes
    # commissioning invent a `temp` profile instead of `default` — the same
    # reason teardown.sh --volumes removes it.
    rm -rf "$IDENTITY_DIR/user-source/default" \
           "$IDENTITY_DIR/user-source/opcua-module" \
           "$IDENTITY_DIR/identity-provider/default"
    rm -rf "$IDENTITY_DIR/user-source/"temp* "$IDENTITY_DIR/identity-provider/"temp*
    SECPROPS_STASH="$(mktemp -d)"
    mv "$SECPROPS_DIR" "$SECPROPS_STASH/security-properties"
    echo -e "${YELLOW}The local gateway commissions on this boot: letting it create the${NC}"
    echo -e "${YELLOW}default identity before restoring the committed security-properties.${NC}"
}

# Self-heal an identity a PREVIOUS boot got wrong. If commissioning ever ran
# with stale identity files in place, the gateway created a `temp` user source
# + identity provider and rewrote the TRACKED security-properties to point at
# it, dropping the APIToken permissions the scan API needs on the way. Nothing
# fails loudly when that happens — the permissions get grafted back and the run
# goes green — so it survives until someone commits the rewritten policy or
# ships it to a gateway that has no `temp` profile (a lockout). Undo it.
heal_temp_identity() {
    local sp="$SECPROPS_DIR/config.json" profile
    [ -f "$sp" ] || return 0
    profile="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("systemAuthProfile",""))
except Exception: pass' "$sp" 2>/dev/null || true)"
    case "$profile" in temp*) ;; *) return 0 ;; esac
    echo ""
    echo -e "${YELLOW}The local gateway is authenticating against a '$profile' identity.${NC}"
    echo "  Commissioning wrote it because identity files outlived their data"
    echo "  volume. Restoring the committed security-properties and dropping it."
    if ! git -C "$PROJECT_ROOT" checkout -- "$SECPROPS_DIR" 2>/dev/null; then
        echo -e "${RED}  Could not restore $SECPROPS_DIR from git — fix it by hand.${NC}" >&2
        return 0
    fi
    rm -rf "$IDENTITY_DIR/user-source/"temp* "$IDENTITY_DIR/identity-provider/"temp*
    if [ ! -d "$IDENTITY_DIR/user-source/default" ]; then
        echo -e "${RED}  No 'default' user source on disk to fall back to.${NC}" >&2
        echo "  Run: scripts/teardown.sh --volumes && scripts/setup.sh" >&2
        return 0
    fi
    docker restart "$(gateway_container local)" >/dev/null
    wait_for_gateway local
    echo -e "${GREEN}  Identity repaired — the gateway is back on 'default'.${NC}"
}

restore_secprops_after_commissioning() {
    [ -n "$SECPROPS_STASH" ] || return 0
    rm -rf "$SECPROPS_DIR"   # drop the commissioning-written version
    mv "$SECPROPS_STASH/security-properties" "$SECPROPS_DIR"
    rmdir "$SECPROPS_STASH" 2>/dev/null || true
    SECPROPS_STASH=""
    echo -e "${GREEN}Restored the committed security-properties; restarting local to load it...${NC}"
    docker restart "$(gateway_container local)" >/dev/null
    wait_for_gateway local
}

stash_secprops_for_commissioning

# ---- Start the stack ------------------------------------------------------
existing_id="$(docker compose ps -q gateway-local-development 2>/dev/null || true)"
if [ -n "$existing_id" ]; then
    echo -e "${YELLOW}Stack already running — 'docker compose up -d' will be a no-op or apply changes.${NC}"
fi
echo -e "${GREEN}Starting the stack...${NC}"
docker compose up -d
echo ""
docker compose ps
echo ""

# ---- Wait for the gateways ------------------------------------------------
wait_for_gateway() {
    local gateway="$1"
    local url
    url="$(gateway_url "$gateway")"
    echo -e "${GREEN}Waiting for $gateway gateway at $url to become RUNNING...${NC}"
    local attempts=0
    local max_attempts=120  # ~4 minutes per gateway; cold start is slow
    while [ $attempts -lt $max_attempts ]; do
        local state
        state="$(curl -fsS "${url}/StatusPing" 2>/dev/null | grep -o RUNNING || true)"
        if [ "$state" = "RUNNING" ]; then
            echo ""
            echo -e "${GREEN}  $gateway gateway RUNNING${NC}"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 2
        echo -n "."
    done
    echo ""
    local container
    container="$(gateway_container "$gateway")"
    echo -e "${RED}Error: $gateway gateway did not reach RUNNING within $((max_attempts * 2))s.${NC}" >&2
    echo "  Check logs:  docker logs --tail 200 $container" >&2
    return 1
}

# Wait for each in series. Could be parallelized; sequential output is
# easier to scan and the total cold-start time is dominated by the JVM
# startup of each gateway anyway.
for gw in "${LAB_GATEWAYS[@]}"; do
    wait_for_gateway "$gw"
done

restore_secprops_after_commissioning
# Runs unconditionally: it repairs a temp identity this run never created, left
# by an earlier boot (or by an older setup.sh that skipped the stash).
heal_temp_identity

# ---- API-permission repair (first boot only) ------------------------------
# On the FIRST boot of a fresh gateway container, Ignition's auto-commissioning
# resets the read/write permissions in security-properties, which locks the
# generated API key out: it still authenticates (bad key = 401) but every
# call gets 403. Detect that and graft the APIToken permissions back
# (scripts/fix-gateway-api-perms.sh restarts the affected gateways). A 401 with
# the correct key means the gateway never LOADED the token resource (e.g. the
# stack was first started with `docker compose up` directly, so the pre-seed
# above never ran before first boot): make sure the token is on disk, restart
# that gateway so it loads it, then fall through to the 403 repair. Later
# setups skip all of this: the data volumes persist, so commissioning runs
# only once.
probe_scan_api() {
    # Each gateway is probed with ITS OWN key from .env.
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
        -H "X-Ignition-API-Token: $(api_key_for "$1")" \
        "$(gateway_url "$1")/data/api/v1/scan/projects" || true
}

repair_api_perms() {
    local needs_fix=() needs_load=()
    local gw code
    for gw in "${LAB_GATEWAYS[@]}"; do
        [ -n "$(api_key_for "$gw")" ] || continue   # no key to probe with
        code="$(probe_scan_api "$gw")"
        case "$code" in
            403) needs_fix+=("$gw") ;;
            401) needs_load+=("$gw") ;;
        esac
    done
    if [ ${#needs_load[@]} -gt 0 ]; then
        echo -e "${YELLOW}API token not loaded yet on: ${needs_load[*]} — seeding the token and restarting...${NC}"
        seed_gateway_state
        for gw in "${needs_load[@]}"; do
            docker restart "$(gateway_container "$gw")" >/dev/null
        done
        for gw in "${needs_load[@]}"; do
            wait_for_gateway "$gw"
            code="$(probe_scan_api "$gw")"
            [ "$code" = "403" ] && needs_fix+=("$gw")
        done
    fi
    [ ${#needs_fix[@]} -eq 0 ] && return 0
    echo -e "${YELLOW}First-boot commissioning reset the API permissions on: ${needs_fix[*]}${NC}"
    echo "Grafting the APIToken permissions back and restarting..."
    "$SCRIPT_DIR/fix-gateway-api-perms.sh" "${needs_fix[@]}"
}

repair_api_perms

# ---- Initial scan (local only) -------------------------------------------
# Local has projects on disk from the bind mount; test/production start empty by
# design (workflows will populate them).
initial_scan() {
    if [ ! -x "$SCRIPT_DIR/scan.sh" ]; then
        echo -e "${YELLOW}scripts/scan.sh missing or not executable, skipping initial scan.${NC}"
        return 0
    fi

    load_api_key_from_env local
    if is_placeholder_api_key; then
        echo -e "${YELLOW}No API key in .env yet — skipping initial scan.${NC}"
        echo "  scripts/generate-api-keys.sh should have created one; run it, then:"
        echo "    scripts/scan.sh local"
        return 0
    fi

    echo -e "${GREEN}Triggering initial scan on local gateway...${NC}"
    if ! "$SCRIPT_DIR/scan.sh" local; then
        echo ""
        echo -e "${YELLOW}Initial scan failed (likely the key lacks scan permission).${NC}"
        echo "  Fix the role for the API key, then run:  scripts/scan.sh local"
    fi
}

initial_scan

# ---- Done -----------------------------------------------------------------
# Pull the actual values from .env so the output matches reality.
ACTUAL_LOCAL_USER="$(env_value GATEWAY_ADMIN_USERNAME_LOCAL)"
ACTUAL_LOCAL_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_LOCAL)"
ACTUAL_TEST_USER="$(env_value GATEWAY_ADMIN_USERNAME_TEST)"
ACTUAL_TEST_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_TEST)"
ACTUAL_PRODUCTION_USER="$(env_value GATEWAY_ADMIN_USERNAME_PRODUCTION)"
ACTUAL_PRODUCTION_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_PRODUCTION)"
ACTUAL_PG_USER="$(env_value POSTGRES_USER)"
ACTUAL_PG_PASS="$(env_value POSTGRES_PASSWORD)"

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
printf "Gateways:\n"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "local"  "http://localhost:8088"  "${ACTUAL_LOCAL_USER:-admin}"  "${ACTUAL_LOCAL_PASS:-(see .env)}"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "test"    "http://localhost:8089"  "${ACTUAL_TEST_USER:-admin}"    "${ACTUAL_TEST_PASS:-(see .env)}"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "production"   "http://localhost:8090"  "${ACTUAL_PRODUCTION_USER:-admin}"   "${ACTUAL_PRODUCTION_PASS:-(see .env)}"
echo ""
echo "TimescaleDB:"
echo "  Host: localhost  Port: 5432"
echo "  Databases: ignition_local_development, ignition_test, ignition_production"
echo "  Username: ${ACTUAL_PG_USER:-ignition}  Password: ${ACTUAL_PG_PASS:-(see .env)}"
echo ""
echo "API keys (unique to this clone, generated into .env — never committed):"
echo "  IGNITION_API_KEY_LOCAL / _TEST / _PRODUCTION — one per gateway;"
echo "  scripts/scan.sh picks the right one from its argument"
echo "  (local | test | production). For CI, copy the"
echo "  _TEST and _PRODUCTION values from .env into the IGNITION_API_KEY"
echo "  secret on the lab-gateway-test / lab-gateway-production GitHub"
echo "  environments."
echo ""
echo "Useful commands:"
echo "  docker compose ps                          # check container state"
echo "  docker logs -f lab06-gateway-local-development        # tail local gateway logs"
echo "  scripts/scan.sh                            # rescan local (default)"
echo "  scripts/scan.sh test                       # rescan test"
echo "  scripts/teardown.sh                        # stop the stack"
echo "  scripts/teardown.sh --volumes              # stop and wipe persistent data"
