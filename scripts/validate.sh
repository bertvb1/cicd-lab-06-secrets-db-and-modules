#!/bin/bash
# validate.sh — local mirror of .github/workflows/ci.yml.
#
# Run this before opening a PR to catch the cheap stuff the CI workflow checks,
# without waiting for a runner:
#   1. Every *.json under projects/ and services/ parses.
#   2. .deployignore patterns are relative (no leading /).
#   3. Secret scan: no real files under secrets/, no known secret values in
#      the gateway payload (projects/ + services/). A full gitleaks history
#      scan is the lab's stretch S3 — it runs in CI, not here.
#   4. security-properties doesn't name a throwaway temp_N identity.
#   5. actionlint passes on .github/workflows/ (only if actionlint is installed).
#
# Exits non-zero if any check fails. No Ignition or Docker needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$PROJECT_ROOT" || exit 1

rc=0

# 1. JSON validity sweep -------------------------------------------------------
echo "→ JSON validity sweep (projects/, services/)"
json_fail=0
while IFS= read -r f; do
  if ! python3 -m json.tool "$f" > /dev/null 2>&1; then
    echo -e "  ${RED}invalid JSON:${NC} $f"
    json_fail=1
  fi
done < <(find projects services -type f -name '*.json' 2>/dev/null)
if [ "$json_fail" -eq 0 ]; then
  echo -e "  ${GREEN}ok${NC} — all JSON parses"
else
  rc=1
fi

# 2. .deployignore syntax ------------------------------------------------------
echo "→ .deployignore syntax (patterns must be relative)"
if [ -f .deployignore ]; then
  di_fail=0
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^/ ]]; then
      echo -e "  ${RED}line $n:${NC} pattern must be relative, not absolute: $line"
      di_fail=1
    fi
  done < .deployignore
  if [ "$di_fail" -eq 0 ]; then
    echo -e "  ${GREEN}ok${NC} — patterns look fine"
  else
    rc=1
  fi
else
  echo "  (no .deployignore — skipped)"
fi

# 3. Secret scan ---------------------------------------------------------------
echo "→ secret scan (secrets/ contents, payload values)"
ss_fail=0

# 3a. Only *.example files and the README may be TRACKED under secrets/.
bad_tracked="$(git ls-files 'secrets/' 2>/dev/null | grep -vE '\.example$|/README\.md$' || true)"
if [ -n "$bad_tracked" ]; then
  while IFS= read -r f; do
    echo -e "  ${RED}secret file committed:${NC} $f — rotate this credential, then remove the file"
  done <<< "$bad_tracked"
  ss_fail=1
fi

# 3b. Untracked real secret files are fine — but only when .gitignore actually
# covers them. A secrets/*.txt that git would pick up is one `git add .` away
# from a burned credential.
while IFS= read -r f; do
  case "$f" in *.example|*README.md) continue ;; esac
  if git ls-files --error-unmatch "$f" > /dev/null 2>&1; then
    continue # already reported by 3a
  fi
  if ! git check-ignore -q "$f" 2>/dev/null; then
    echo -e "  ${RED}not gitignored:${NC} $f — fix .gitignore before doing anything else"
    ss_fail=1
  fi
done < <(find secrets -type f 2>/dev/null)

# 3c. None of the lab's known secret values may appear in the gateway payload.
for ex in secrets/*.example; do
  [ -f "$ex" ] || continue
  value="$(cat "$ex")"
  [ -n "$value" ] || continue
  if hits="$(grep -rl -F "$value" projects/ services/ 2>/dev/null)"; then
    while IFS= read -r f; do
      echo -e "  ${RED}secret value from $ex found in:${NC} $f — use a referenced secret instead"
    done <<< "$hits"
    ss_fail=1
  fi
done

if [ "$ss_fail" -eq 0 ]; then
  echo -e "  ${GREEN}ok${NC} — no secrets where they shouldn't be"
else
  rc=1
fi

# 4. identity policy -----------------------------------------------------------
# security-properties is tracked and DEPLOYED, so whatever it names has to
# exist on every gateway. Commissioning rewrites it to a throwaway `temp_N`
# profile when it runs with identity files that outlived their data volume
# (scripts/setup.sh heals that) — and a temp profile exists on exactly one
# gateway, so committing it ships an auth policy pointing at nothing. Cheap
# check, because the failure mode is a locked-out gateway.
echo "→ identity policy (security-properties names a deployable profile)"
secprops="services/config/resources/core/ignition/security-properties/config.json"
if [ -f "$secprops" ]; then
  bad_profile="$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(" ".join(sorted({v for k,v in d.items()
                       if k in ("systemAuthProfile","systemIdentityProvider")
                       and str(v).startswith("temp")})))' "$secprops" 2>/dev/null || true)"
  if [ -n "$bad_profile" ]; then
    echo -e "  ${RED}security-properties points at a throwaway identity:${NC} $bad_profile"
    echo "  A commissioning run rewrote it. Restore it and drop the temp identity:"
    echo "    git checkout -- $secprops"
    echo "    rm -rf services/config/resources/core/ignition/{user-source,identity-provider}/temp*"
    echo "  (or just re-run scripts/setup.sh, which now repairs this)"
    rc=1
  else
    echo -e "  ${GREEN}ok${NC} — no throwaway identity in the deploy payload"
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — $secprops not found"
fi

# 5. actionlint (optional) -----------------------------------------------------
echo "→ actionlint (.github/workflows/)"
if command -v actionlint > /dev/null 2>&1; then
  if actionlint -color; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — actionlint not installed (CI runs it; install from https://github.com/rhysd/actionlint to check locally)"
fi

echo ""
if [ "$rc" -eq 0 ]; then
  echo -e "${GREEN}validate.sh: all checks passed${NC}"
else
  echo -e "${RED}validate.sh: one or more checks failed${NC}"
fi
exit "$rc"
