# secrets/ — file-based secrets for the lab stack

Only the `*.example` files (and this README) are tracked. Real secret files
(`*.txt`) are gitignored and never leave the machine they were written on.

## Local use (Part 1A of the lab)

Create the real files from the committed examples:

```bash
cp secrets/postgres_password.txt.example secrets/postgres_password.txt
cp secrets/reporting_password.txt.example secrets/reporting_password.txt
```

Keep the same values as the examples: Postgres only sets passwords on first
volume init, so changing the value here does NOT change it in an existing
database volume. These files exist to change **where the value lives**
(env var → file), not the value itself.

The files are written **without a trailing newline** (`printf '%s'`, not
`echo`) — a newline would become part of the password for consumers that read
the file verbatim.

## Deployed environments (Part 1C)

The test/production hosts never get these files from Git. The deploy workflow
materializes them from GitHub environment secrets (`umask 177` + `printf`)
right before shipping — see `.github/workflows/deploy.yml`.

## Rules

- If `git status` ever lists a file here that isn't a `*.example`, stop and
  fix `.gitignore` before doing anything else.
- A pushed secret is a burned secret: rotate first, scrub second.
  See `docs/secrets-management.md`.
