#!/bin/bash
# One-shot setup for the lab 04 stack:
#   - sanity-checks the host (docker compose v2, curl, WSL quirks)
#   - installs the repo's git hooks (skip-worktree for the machine-local
#     Ignition config file) and a diff driver that hides volatile resource.json
#     metadata; volatile-only churn is undone with
#     scripts/clean-ignition-resource-churn.sh
#   - ensures .env is in place
#   - brings up the stack (three Ignition gateways + shared TimescaleDB)
#   - waits for ALL THREE gateways to become RUNNING
#   - triggers an initial projects + config scan against the LOCAL gateway
#     (only if its API key in .env is real, not the example placeholder).
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
    for hook in post-merge post-checkout post-rewrite; do
        local target="$repo_hooks_dir/$hook"
        ln -sf "$source_dir/$hook" "$target"
    done
    if [ -x "$source_dir/skip-worktree-ignition-resources" ]; then
        "$source_dir/skip-worktree-ignition-resources" || true
    fi
}

install_git_hooks

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
    echo -e "${YELLOW}are filled in after first login to each gateway.${NC}"
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

# ---- Test/production gateway state dirs + API-token pre-seed ----------------------
# test and production bind-mount ./gateways/<gw>/{projects,config} (see
# docker-compose.yaml) so you can verify a deploy landed straight from the
# host: `ls gateways/test/projects`. Create the dirs before compose up and
# pre-seed the committed `cicd` API token into config/ BEFORE the gateway's
# first boot: the scan API only accepts tokens the gateway has LOADED, and
# the deploy workflow cannot scan its own token in (chicken-and-egg — the
# scan call already needs it). With the token on disk at first boot the
# gateway loads it while commissioning; the 403 that commissioning's
# permission reset causes is repaired further down.
seed_gateway_state() {
    local gw token_src manifest_src core_dst
    token_src="$PROJECT_ROOT/services/config/resources/core/ignition/api-token"
    # The collection manifest MUST accompany any pre-seeded resource: on first
    # boot the gateway creates the `core` collection and refuses a non-empty
    # dir that has no manifest ("Resource collection path ... exists but is
    # not empty" -> FAULTED).
    manifest_src="$PROJECT_ROOT/services/config/resources/core/config-mode.json"
    for gw in test production; do
        mkdir -p "$PROJECT_ROOT/gateways/$gw/projects" "$PROJECT_ROOT/gateways/$gw/config"
        core_dst="$PROJECT_ROOT/gateways/$gw/config/resources/core"
        if [ -d "$token_src" ] && [ -f "$manifest_src" ] \
           && [ ! -d "$core_dst/ignition/api-token" ]; then
            mkdir -p "$core_dst/ignition"
            cp "$manifest_src" "$core_dst/config-mode.json"
            cp -R "$token_src" "$core_dst/ignition/"
        fi
        # Per-gateway module manifest (see docker-compose.yaml): seed it from
        # the repo's manifest so the first boot has one; from then on ONLY
        # deploy.yml updates it. Must exist before compose up, or Docker
        # turns the single-file bind mount into an empty directory.
        if [ ! -f "$PROJECT_ROOT/gateways/$gw/modules.json" ]; then
            cp "$PROJECT_ROOT/services/modules.json" "$PROJECT_ROOT/gateways/$gw/modules.json"
        fi
    done
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

# ---- Local first-boot: stash security-properties during commissioning -----
# On the very first boot of the LOCAL gateway, auto-commissioning has to
# guarantee an admin login exists. If it finds a security-properties file but
# no matching user source (the repo tracks the policy file; the per-gateway
# user-source/default is gitignored), it plays safe and creates a temp_N
# identity, then rewrites security-properties to point at it — permanent git
# noise AND an auth profile no other gateway has. If it finds NO
# security-properties, it creates the `default` user source + identity
# provider, exactly like test/production do. So: move the committed file aside for
# the first boot, then put it back (it names systemAuthProfile=default, which
# now exists, and carries the APIToken scan permissions) and restart local.
SECPROPS_DIR="$PROJECT_ROOT/services/config/resources/core/ignition/security-properties"
SECPROPS_STASH=""
stash_secprops_for_commissioning() {
    local usersource_dir="$PROJECT_ROOT/services/config/resources/core/ignition/user-source/default"
    # If a previous interrupted run left the file stashed away, recover the
    # committed version from git before deciding anything.
    if [ ! -d "$SECPROPS_DIR" ]; then
        git -C "$PROJECT_ROOT" checkout -- "$SECPROPS_DIR" 2>/dev/null || true
    fi
    if [ -d "$usersource_dir" ] || [ ! -d "$SECPROPS_DIR" ]; then
        return 0   # not a first boot (or nothing to stash)
    fi
    SECPROPS_STASH="$(mktemp -d)"
    mv "$SECPROPS_DIR" "$SECPROPS_STASH/security-properties"
    echo -e "${YELLOW}First boot of the local gateway: letting commissioning create the${NC}"
    echo -e "${YELLOW}default identity before restoring the committed security-properties.${NC}"
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

# ---- API-permission repair (first boot only) ------------------------------
# On the FIRST boot of a fresh gateway container, Ignition's auto-commissioning
# resets the read/write permissions in security-properties, which locks the
# pre-provisioned API key out: it still authenticates (bad key = 401) but every
# call gets 403. Detect that and graft the APIToken permissions back
# (scripts/fix-gateway-api-perms.sh restarts the affected gateways). A 401 with
# the correct key means the gateway never LOADED the token resource (e.g. the
# stack was first started with `docker compose up` directly, so the pre-seed
# above never ran before first boot): make sure the token is on disk, restart
# that gateway so it loads it, then fall through to the 403 repair. Later
# setups skip all of this: the data volumes persist, so commissioning runs
# only once.
probe_scan_api() {
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
        -H "X-Ignition-API-Token: $IGNITION_API_KEY" \
        "$(gateway_url "$1")/data/api/v1/scan/projects" || true
}

repair_api_perms() {
    load_api_key_from_env local
    if is_placeholder_api_key; then
        return 0   # no key to probe with; initial_scan prints the guidance
    fi
    local needs_fix=() needs_load=()
    local gw code
    for gw in "${LAB_GATEWAYS[@]}"; do
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
        echo "  The lab ships a pre-provisioned token; copy the IGNITION_API_KEY_* lines"
        echo "  from .env.example into .env, then run:"
        echo "    scripts/scan.sh both --gateway local"
        return 0
    fi

    echo -e "${GREEN}Triggering initial scan on local gateway...${NC}"
    if ! "$SCRIPT_DIR/scan.sh" both --gateway local; then
        echo ""
        echo -e "${YELLOW}Initial scan failed (likely the key lacks scan permission).${NC}"
        echo "  Fix the role for the API key, then run:  scripts/scan.sh both --gateway local"
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
if is_placeholder_api_key; then
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  The lab ships a pre-provisioned API token (services/config/.../api-token/cicd);"
    echo "  copy the IGNITION_API_KEY_* lines from .env.example into .env — the same key"
    echo "  works on all three gateways."
    echo "  The deploy/release workflows take their keys from GitHub secrets on"
    echo "  the lab-gateway-test / lab-gateway-production environments — set those too"
    echo "  when you're ready to run CI."
    echo ""
fi
echo "Useful commands:"
echo "  docker compose ps                          # check container state"
echo "  docker logs -f lab06-gateway-local-development        # tail local gateway logs"
echo "  scripts/scan.sh both               # rescan local (default)"
echo "  scripts/scan.sh both --gateway test # rescan test"
echo "  scripts/teardown.sh                        # stop the stack"
echo "  scripts/teardown.sh --volumes              # stop and wipe persistent data"
