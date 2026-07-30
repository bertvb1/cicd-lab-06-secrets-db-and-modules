# Fresh-clone permission fixes — porting notes for the other labs

Branch: `fix/fresh-clone-permissions` — pushed to both
`Mustry-Academy/cicd-lab-06-secrets-db-and-modules` and the `bertvb1` fork
(commits `000129b`, `85fd23f`, `59026ef`; also merged into the fork's main).
Found and verified live on a fresh-clone run of Lab 06 on WSL2, 2026-07-22.
Any lab that took the no-sudo permissions rework (`5a6f09e` —
`user: "2003:0"` + `group_add: ${LAB_GID}` + `scripts/preflight.sh`) has the
same four problems.

## Symptom that surfaced it

First `scripts/setup.sh` on a fresh clone: local gateway comes up, **test
gateway FAULTs** and never reaches RUNNING. `docker logs` shows
`java.nio.file.AccessDeniedException: data/modules.json` and
`unable to create resource dir: .../data/config/resources/.resources`.
A second setup run "fixes" it, which is why it survives casual testing.

## Fix 1 — setup.sh: bind-mount perms are applied before the dirs exist

`lab_preflight` (and its `pf_prepare_bind_mounts` chmod pass) runs at the top
of setup.sh, but `seed_gateway_state` creates `gateways/test|production/{projects,config}`
and the api-token resources *later*. `pf_prepare_bind_mounts` "only touches
dirs that exist", so on a fresh clone those trees are born under the student's
umask (022 → no group write) and the gateway (uid 2003, writing via the
student's group) cannot write.

**Change:** call `pf_prepare_bind_mounts` again at the end of
`seed_gateway_state`, after `generate-api-keys.sh`. (preflight.sh is already
sourced by setup.sh, so the function is available.)

**Port to other labs:** anywhere setup.sh (or any script) `mkdir`s or copies
files into a tree a container will write to, re-apply the group-write/setgid
pass *after* creating them — or create them with `install -d -m 2775`.

## Fix 2 — docker-compose.yaml: the gateway writes group-read-only files

The design promise is "everything the gateway writes is editable/deletable by
the student, no sudo ever". But the Ignition image runs with umask 022, so
gateway-written files land 644/755 — group read-only — despite `group_add` +
setgid dirs. Concrete breakage: `teardown.sh --volumes` fails with
`Permission denied` trying to remove the commissioning-written
`user-source/default` files; students cannot edit gateway-written config.

**Change:** start each gateway service through a umask wrapper (YAML anchor,
referenced by all three gateway services):

```yaml
x-ignition-entrypoint: &ignition-entrypoint
  ["/bin/sh", "-c", 'umask 0002 && exec docker-entrypoint.sh "$@"', "--"]
# per gateway service:
    entrypoint: *ignition-entrypoint
```

**Port to other labs:** every compose file with the `user: "2003:0"` +
`group_add` pattern needs the same wrapper (adjust the entrypoint name if the
image differs).

## Fix 3 — preflight.sh: reclaim prompt fires on the gateway's own files

`pf_reclaim_root_owned` counts every file `! -user $me` as sudo damage. Once a
gateway has written anything into the bind mounts (uid 2003), every later
setup.sh re-run prompts "Reclaim them with sudo chown?" for files that are
fine by design.

**Change:** exclude uid 2003 in both the detection and the examples listing:

```bash
find . -xdev ! -user "$me" ! -user 2003 -print -quit ...
```

Root/foreign-uid files (the actual damage) still trigger the prompt.

## Fix 4 — deploy.yml: docker cp ships root-owned files the gateway can't use

The "Ship projects and config" step does `docker cp ./projects/. …` and
`docker cp ./services/config/. …`. `docker cp` writes as **root**, so the
first deploy leaves the whole shipped tree root:root 755. The first-deploy
restart then FAULTs the gateway (`unable to create resource dir:
.../config/resources/.resources` — uid 2003 can't write into root-owned
dirs) and the workflow's `wait_for_running` times out after 5 minutes.
Deceptive detail: the container healthcheck stays *green* — StatusPing
answers on a FAULTED gateway; only the workflow's grep for RUNNING fails.

The secrets step already knew ("docker cp writes as root; the gateway must
be able to read") and chowns after copying; upstream `e36d8ea` (2026-07-22)
gave `/run/secrets` the same treatment — the main payload path was the last
one missing it.

**Change:** after the two `docker cp` lines, add:

```bash
docker exec -u root "$IGNITION_CONTAINER" sh -c "
  set -eu
  gid=\$(stat -c %g '$GATEWAY_DATA_PATH/config')
  chown -R 2003:\"\$gid\" '$GATEWAY_DATA_PATH/projects' '$GATEWAY_DATA_PATH/config'
  chmod -R g+w '$GATEWAY_DATA_PATH/projects' '$GATEWAY_DATA_PATH/config'
  find '$GATEWAY_DATA_PATH/projects' '$GATEWAY_DATA_PATH/config' -type d -exec chmod g+s {} +
"
```

(The gid is read from the bind mount so host-side editability survives.)

**Port to other labs:** any workflow that `docker cp`s into a container
running as uid 2003 needs a chown after every cp — projects, config,
third-party-modules, wherever. Grep the workflows for `docker cp`.

**Repairing a gateway already broken by this:** run the same
`docker exec -u root … chown/chmod` against the container, then
`docker restart` it.

## Why testing missed all four

Fixes 1–3: `scripts/test-preflight.sh` validates the *end state*: it
`chmod -R g+w`s the whole repo up front (line ~234) and probes writability
with a forced `umask 002` (line ~236). It never exercises the
fresh-clone-first-run sequence and never uses the gateway's real umask.
Worth adding a test case: wipe volumes + `gateways/` + generated config,
run setup.sh once, assert all gateways reach RUNNING and that a
container-written file is group-writable.

Fix 4: the fork-side pipeline runs were still an open item
(exercises/lab.md infra-status comment) — the first real
workflow_dispatch deploy is what surfaced it.

## Verified end to end (2026-07-22)

- Fresh-clone `setup.sh` first run: all three gateways RUNNING, initial
  scan HTTP 200, everything the gateways wrote group-editable.
- `teardown.sh --volumes`: completes without sudo or permission errors.
- Deploy workflow (fixed): green to test twice (dispatch + push-trigger),
  green to production; shipped trees land `2003:<student group>` 775/664.

One operational gotcha worth passing to students: `workflow_dispatch`
snapshots the chosen ref *at dispatch time*. A production deploy dispatched
minutes before the fix merged ran the old workflow and FAULTed the
production gateway — repaired with the recipe under Fix 4.

## Smaller nit spotted along the way (not fixed)

If setup.sh dies between stashing and restoring the committed
`security-properties` (e.g. a gateway wait times out), the commissioning-
written version stays in the working tree as a tracked modification. The
recovery path in `stash_secprops_for_commissioning` only handles the
*deleted* case (`git checkout` when the dir is missing), not the
*overwritten* one. Consider `git checkout -- "$SECPROPS_DIR"` when the
working-tree version differs and no stash is pending.

## Verification recipe used

```bash
CI=1 scripts/teardown.sh --volumes        # now succeeds without sudo
git clean -fdXq services/config projects gateways
git checkout -- services/config
scripts/setup.sh                          # fresh-clone first run: all 3 gateways RUNNING
find gateways services/config -xdev ! -perm -g=w ! -type l   # only Ignition's own 600 digest caches
```
