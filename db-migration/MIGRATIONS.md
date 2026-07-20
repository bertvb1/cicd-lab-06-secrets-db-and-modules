# Database migrations — the rules

Schema changes ship as [golang-migrate](https://github.com/golang-migrate/migrate)
files under `db-migration/migrate/`, applied with `scripts/migrate.sh`. The
`db-init/` folder is **bootstrap** (runs once, on an empty database volume);
this folder is **deployment** (runs on every environment, in order, forever).

## File naming

```
db-migration/migrate/
├── 0001_create_production_kpi.up.sql
├── 0001_create_production_kpi.down.sql
├── 0002_<descriptive_name>.up.sql      ← next change goes here
└── 0002_<descriptive_name>.down.sql
```

- 4-digit sequence number, `snake_case` descriptive name.
- `.up.sql` applies the change; `.down.sql` undoes **exactly** that change.

## The two rules the tool will NOT enforce for you

1. **All migrations come in pairs.** Every `.up.sql` has a `.down.sql` that
   reverses it. No down, no merge.
2. **Never edit a migration that has been deployed anywhere.** golang-migrate
   only tracks the applied *position* (the `schema_migrations` table), not the
   file *content* — editing an applied file silently diverges every other
   environment. Changes go in the next number.

Together they keep every environment replayable from zero: a fresh database +
`migrate up` = production schema, bit for bit.

## Day-to-day

```bash
scripts/migrate.sh up                          # apply pending on ignition_local_development
scripts/migrate.sh up --database ignition_test  # apply pending on test
scripts/migrate.sh down 1                      # roll back one step
scripts/migrate.sh version                     # where am I?
```

The ledger lives in the target database:

```bash
docker exec lab06-timescaledb psql -U ignition -d ignition_local_development \
  -c 'SELECT * FROM schema_migrations;'
```

A schema change and the screens that need it travel in the **same PR**, and
the pipeline applies the migration **before** it ships the screens — old
screens tolerate a new table; new screens don't tolerate a missing one.
