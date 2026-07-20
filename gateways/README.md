# gateways/ — test and production gateway state

This folder holds the **test** and **production** gateways' `projects/` and `config/`
directories, bind-mounted into their containers (see `docker-compose.yaml`):

```
gateways/
├── test/
│   ├── projects/      ← what deploy.yml shipped (push to main)
│   ├── config/        ← gateway config, incl. what the deploy copied
│   └── modules.json   ← this gateway's module manifest (what it last booted with)
└── production/
    ├── projects/      ← what deploy.yml shipped (dispatch, target=production)
    ├── config/
    └── modules.json
```

The `modules.json` copies are deliberately separate from the repo's
`services/modules.json` (which only the **local** gateway mounts): test/production
must run what was *deployed*, not what your working tree happens to contain.
The deploy workflow updates them and restarts the gateway only when the
manifest actually changed.

`scripts/setup.sh` creates these subdirectories (and pre-seeds the `cicd` API
token) before the gateways' first boot. Everything except this README is
**gitignored** — it is the *gateways'* state, not the repo's.

Why bind mounts instead of named volumes: you can verify a deploy landed
without touching Docker at all:

```bash
ls gateways/test/projects            # what did the last test deploy ship?
ls gateways/production/projects           # and the last release?
```

Treat these directories as **read-only**: they are fed by CI (`docker cp` +
scan from the workflows). Editing them by hand defeats the pipeline you are
building — change `projects/` or `services/config/` in the repo and let a
deploy ship it instead.
