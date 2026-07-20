# Multi-gateway promotion pattern — cheat sheet

Reference reading for Lab 06. How one artifact travels through a chain of gateways, what gates each hop, and where per-environment differences are allowed to live.

## The pattern in one picture

```
                 build ONCE                        promote (re-tag, never rebuild)
feature/* ─PR→ develop ──▶ deploy.yml ──▶ :sha + :test ──▶ TEST        automatic on merge
                  │
                  └─ release/1.x ──▶ promote.yml ──▶ :test → :staging ──▶ STAGING   release branch = freeze point
                        │
                        └─PR→ main ─tag v1.x.y─▶ release.yml ──▶ :staging → :v1.x.y + :production ──▶ PRODUCTION
                                                                  ▲
                                                     human approval (GitHub environment
                                                     required reviewers) blocks here
```

Three invariants:

1. **Build once.** The only `docker build` happens on the push to `develop`. Every promotion is `docker buildx imagetools create` — a server-side re-tag. The digest that reaches production is byte-identical to what staging ran on day one of the release.
2. **Promote from the stage below.** `release.yml` re-tags `:staging`, not `:test`. By release time, `develop` (and therefore `:test`) has usually moved on — promoting `:test` would ship work that never went through acceptance. Promoting the tagged commit doesn't work either: in Git Flow the release merge into `main` creates a commit SHA no image was ever built for.
3. **One artifact, all environments.** The image contains every scope overlay (`local-development`, `test`, `staging`, `production`). The gateway's boot flag decides which one applies. Deploying to a new environment never requires a rebuild — only a new overlay and a boot flag.

## Why a staging stage at all?

Test answers "does my change work?" Staging answers a different question: "**is this frozen set of changes, as a whole, ready for production?**"

- Test is *volatile* — it changes on every merge to `develop`. You can never sign off on test, because it may change under you between the sign-off and the release.
- The `release/*` branch is the **freeze point**. Pushing it promotes the current `:test` image to staging, and from that moment staging is stable while `develop` keeps moving. Acceptance testing, customer demos, and operator training happen against staging.
- Fixes found during acceptance go onto the `release/*` branch (and merge back to `develop`), re-promoting to staging. <!-- [VERIFY] promote.yml behavior for follow-up pushes to an existing release branch: a fix commit means the release branch no longer matches :test — decide whether promote.yml rebuilds from the release branch, or the fix must go through develop first. This is THE design decision to nail down before the course. -->

## Gates between stages

| Hop | Gate | Mechanism |
|---|---|---|
| feature → develop | code review + CI green | PR + branch protection (`ci.yml`) |
| develop → test | none — automatic | `deploy.yml` on push |
| test → staging | a human decides "freeze now" | pushing the `release/*` branch |
| staging → production | acceptance passed **and** a human approves | tag `v*` + **required reviewers** on the `lab-gateway-production` environment |

The production gate needs **zero workflow changes** — it's a property of the GitHub environment. That's the pattern to remember: workflows say *what happens*, environments say *what's allowed to happen and by whom*.

Gates worth adding beyond the lab: automated smoke tests against the freshly deployed stage (fail → block promotion), a change-window check (only deploy production inside the maintenance window), and a "digest equality" assertion that refuses to deploy production if staging's digest doesn't match the promoted tag.

## Branch-per-environment: the anti-pattern

The tempting alternative: a long-lived branch per environment (`test`, `staging`, `production` branches) where deploying = merging up the chain. Avoid it:

- **The artifact is rebuilt per branch**, so production runs a *different build* than the one you tested — different base image pull, different timestamps, occasionally different dependency resolutions.
- **Branches drift.** A hotfix merged to `production` but not back to `test` means next release *un-fixes* production. Merge conflicts between environment branches are conflicts between *environments*, which is a category error.
- **Config leaks into code history.** Teams start committing env-specific values directly on env branches, and now the same file differs across branches forever.

Build-once/promote-many replaces all of that with tags on one immutable artifact. Git history describes the *product*; the registry tags describe *where each build stands in the pipeline*.

## The three buckets

Every configuration value belongs to exactly one bucket. Getting this classification right is most of "configuration management".

| Bucket | Rule | Lives in | Examples |
|---|---|---|---|
| **Core** | identical in every environment | `services/config/resources/core/` — in git, in the image | historian provider settings, tag providers, identity provider config, Perspective session props |
| **Overlay** | differs per environment, safe to read | `services/config/resources/<env>/` — in git, in the image | DB `connectURL`, OPC UA endpoints, gateway network targets, alarm SMTP host |
| **Secret** | differs per environment, must not be readable | **not in git, not in the image** — injected at deploy/boot time | DB passwords, API keys, PATs, cloud creds |

Notes on the tricky rows from the lab's inventory drill:

- **Identity provider**: the *configuration* (which IdP, which mappings) is usually core; the *client secret* inside it is a secret. One resource can straddle buckets — 8.3's encrypted fields blur this, but "encrypted blob in git" is still a smell (see Lab 07).
- **`modules.json`**: core in spirit (the module *set* should not differ between test and production — otherwise you're not testing production), but note it's a sibling of `config/`, not inside the scope tree.
- **Memory limits, ports, admin credentials**: not config-scope territory at all — they're **boot-time** knobs (compose/env vars). Which layer a knob belongs to matters as much as which bucket.

## The three layers (when a value takes effect)

| Layer | Set where | Changed by | Examples |
|---|---|---|---|
| **Bake-time** | Dockerfile / image content | new image build | projects, module `.modl` files, all scope overlays |
| **Boot-time** | compose env vars + JVM args | recreate container | `-Dignition.config.mode`, admin creds, memory, ports, `GATEWAY_MODULES_ENABLED` |
| **Run-time** | gateway API / scan | no restart | project resources via file-based scan (Lab 04's inner loop) |

The multi-gateway insight: overlays are **bake-time content** but their *selection* is **boot-time**. That's what lets one image serve every environment.

## Ignition 8.3 config scopes, mechanically

Each scope directory carries a `config-mode.json` descriptor with a `parent` field, forming the chain `external → core → <env>`. The gateway boots with `-Dignition.config.mode=<scope>` and resolves any resource by walking the chain child-first: `<env>` wins over `core`, `core` wins over `external`. <!-- [VERIFY] exact resolution semantics (deep-merge per key vs whole-resource replacement) — test with a partial override before teaching it as fact. The lab's existing overlays override the entire config.json, which is the safe assumption. -->

```
services/config/resources/
├── external/config-mode.json      {parent: "system"}   ← Ignition defaults
├── core/config-mode.json          {parent: "external"} ← shared, versioned
│   └── ignition/database-connection/TimescaleDB/{config.json, resource.json}
├── local-development/  test/  staging/  production/         {parent: "core"}     ← one folder per environment
│   └── ignition/database-connection/TimescaleDB/config.json   ← same name, different connectURL
└── local/                          ← per-instance state (uuids, keystores) — never shipped
```

## Fan-out: one release, N gateways

Vertical stages (test→staging→production) get a build to production. Horizontal fan-out gets it to *every* production gateway — lines, sites, redundant pairs:

```yaml
deploy:
  strategy:
    matrix:
      gateway: [production, production-b]      # or include: site/runner-label pairs
    max-parallel: 1                # canary: one gateway at a time, stop on failure
  runs-on: [self-hosted, "${{ matrix.gateway }}"]   # real fleets: one runner label per site
```

Fleet rules of thumb:

- **Uniform artifact**: every gateway in the fleet runs the same digest; differences are overlays only. "Which version is line B on?" must be answerable with `docker inspect`, not archaeology.
- **Canary order**: least-critical gateway first, `max-parallel: 1`, health-gated. A failed healthcheck must *halt* the rollout, not skip the gateway.
- **Rollback is the same move as deploy**: re-run the release workflow with the previous tag. If rollback has different mechanics than deploy, it will fail exactly when you need it.
- **Partial fleet is the steady state during a rollout** — design for it (versions visible on a status view, alarms tolerant of mixed versions), don't pretend it away.

## What this lab leaves out (on purpose)

- **Secrets** — every password in these overlays is an encrypted-blob-in-git. Lab 07 replaces that with real secret injection.
- **Redundant pairs** — Ignition redundancy (master/backup) is licensing + gateway-network territory, out of CI/CD scope here. Treat a redundant pair as *one* deploy target. <!-- [VERIFY] worth a slide-level mention only -->
- **Gateway network / EAM** — Ignition's own multi-gateway tooling (EAM agents pushing projects) is an alternative delivery mechanism to this whole pattern; a debrief talking point, not a lab exercise.
