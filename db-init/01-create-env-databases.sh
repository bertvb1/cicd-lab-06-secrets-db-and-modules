#!/bin/bash
# Runs ONCE, when the timescaledb container first initializes an empty data
# volume. This is BOOTSTRAP, not deployment: an existing volume never
# re-runs it (that's the whole point of Part 2 of the lab — schema changes
# to a live database ship as migrations, not as edits to this script).
#
# Creates:
#   - the per-environment databases (ignition_local_development comes from POSTGRES_DB in
#     docker-compose.yaml; test + production are created here)
#   - the read-only `reporting` user that the TimescaleDB_Reports gateway
#     connection logs in with. Its password comes from REPORTING_PASSWORD /
#     REPORTING_PASSWORD_FILE on the timescaledb service — same _FILE
#     convention Postgres itself uses for POSTGRES_PASSWORD.
set -euo pipefail

# _FILE variant wins if set (file-based secrets, Part 1A of the lab).
if [ -n "${REPORTING_PASSWORD_FILE:-}" ] && [ -f "${REPORTING_PASSWORD_FILE}" ]; then
    REPORTING_PASSWORD="$(< "${REPORTING_PASSWORD_FILE}")"
fi
: "${REPORTING_PASSWORD:?REPORTING_PASSWORD (or REPORTING_PASSWORD_FILE) must be set on the timescaledb service}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE DATABASE ignition_test;
CREATE DATABASE ignition_production;

-- Read-only reporting login. pg_read_all_data grants SELECT on every table
-- in every database, current and future — exactly what a reporting tool
-- needs and nothing more.
CREATE ROLE reporting LOGIN PASSWORD '${REPORTING_PASSWORD}';
GRANT pg_read_all_data TO reporting;
SQL
