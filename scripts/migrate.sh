#!/bin/bash
# migrate.sh — run golang-migrate in Docker against the lab's TimescaleDB,
# the same way our file-based production repo does it. No local install
# needed; the tool runs from the migrate/migrate image on the stack's own
# Docker network.
#
# Usage:
#   scripts/migrate.sh up [N]                       # apply all (or N) pending
#   scripts/migrate.sh down N                       # roll back N steps
#   scripts/migrate.sh version                      # current position + dirty flag
#   scripts/migrate.sh <cmd> --database ignition_test   # target another env's DB
#
# The applied position is tracked in the target database's schema_migrations
# table:
#   docker exec lab06-timescaledb psql -U ignition -d ignition_local_development \
#     -c 'SELECT * FROM schema_migrations;'
#
# Password resolution, first hit wins (mirrors the secrets ladder of this lab):
#   1. POSTGRES_PASSWORD in the environment (CI materializes secrets there)
#   2. secrets/postgres_password.txt (file-based secret, Part 1A)
#   3. POSTGRES_PASSWORD in .env
#   4. the compose default (lab06-postgres-pw)

set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$PROJECT_ROOT"

MIGRATE_IMAGE="migrate/migrate:v4.17.1"
DB_CONTAINER="lab06-timescaledb"
MIGRATIONS_DIR="$PROJECT_ROOT/db-migration/migrate"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---- parse args -------------------------------------------------------------
DATABASE="ignition_local_development"
CMD_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --database) DATABASE="${2:?--database needs a value}"; shift 2 ;;
    --database=*) DATABASE="${1#--database=}"; shift ;;
    -h|--help) usage ;;
    *) CMD_ARGS+=("$1"); shift ;;
  esac
done
[ ${#CMD_ARGS[@]} -gt 0 ] || usage

# ---- resolve credentials ----------------------------------------------------
PG_USER="${POSTGRES_USER:-$(env_value POSTGRES_USER)}"
PG_USER="${PG_USER:-ignition}"

PG_PASS="${POSTGRES_PASSWORD:-}"
if [ -z "$PG_PASS" ] && [ -f "$PROJECT_ROOT/secrets/postgres_password.txt" ]; then
  PG_PASS="$(< "$PROJECT_ROOT/secrets/postgres_password.txt")"
fi
if [ -z "$PG_PASS" ]; then
  PG_PASS="$(env_value POSTGRES_PASSWORD)"
fi
PG_PASS="${PG_PASS:-lab06-postgres-pw}"

# ---- find the stack's network -----------------------------------------------
if ! docker inspect "$DB_CONTAINER" > /dev/null 2>&1; then
  echo -e "${RED}Error: container '$DB_CONTAINER' not found — is the stack up? (scripts/setup.sh)${NC}" >&2
  exit 1
fi
NETWORK="$(docker inspect "$DB_CONTAINER" \
  --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}')"
if [ -z "$NETWORK" ]; then
  echo -e "${RED}Error: could not determine the Docker network of $DB_CONTAINER.${NC}" >&2
  exit 1
fi

# ---- run migrate ------------------------------------------------------------
# create + docker cp + start instead of a bind mount: it works identically on
# the host AND inside the containerized CI runner (where a bind-mount source
# path would resolve against the host's filesystem, not the runner's).
DB_URL="postgres://${PG_USER}:${PG_PASS}@timescaledb:5432/${DATABASE}?sslmode=disable"
echo -e "${GREEN}migrate ${CMD_ARGS[*]} → ${DATABASE} (network: ${NETWORK})${NC}"

cid="$(docker create --network "$NETWORK" "$MIGRATE_IMAGE" \
  -path=/migrations -database "$DB_URL" "${CMD_ARGS[@]}")"
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() { docker rm -f "$cid" > /dev/null 2>&1 || true; }
trap cleanup EXIT

docker cp "$MIGRATIONS_DIR/." "$cid:/migrations/" > /dev/null
rc=0
docker start -a "$cid" || rc=$?

if [ "$rc" -ne 0 ]; then
  echo -e "${RED}migrate exited with status $rc${NC}" >&2
  echo "  If the ledger is 'dirty', fix the failed migration and use:" >&2
  echo "    scripts/migrate.sh force <version> --database $DATABASE" >&2
fi
exit "$rc"
