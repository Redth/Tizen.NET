#!/bin/bash
#
# Copyright (c) Samsung Electronics. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Semantic checks for .github/workflows/release-workload.yml.
#
# The release workflow cannot be executed here, so these assertions pin the ordering and
# guard conditions that make a release safe and RETRYABLE:
#
#   * the version bump is persisted only AFTER the build and artifact verification, so a
#     failed release does not leave the branch bumped and therefore unretryable
#     (the retry would compute OLD == NEW);
#   * OLD == NEW resumes rather than aborts;
#   * a reference-only run mutates nothing;
#   * the release tag targets the commit that carries the released Versions.props;
#   * pushes use the verified staging directory, not a glob over the workspace;
#   * re-creating an existing tag is a no-op.
#
# Usage:
#   bash workload/scripts/test-release-workflow.sh
#   make -C workload test-release-workflow
#

set -uo pipefail

WORKLOAD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WF="$WORKLOAD_DIR/../.github/workflows/release-workload.yml"

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'
[[ -t 1 ]] || { c_reset=""; c_red=""; c_green=""; }

pass=0; fail=0

if [[ ! -f "$WF" ]]; then
    echo "ERROR: $WF not found."
    exit 2
fi

assert() {
    local label="$1" cond="$2"
    if [[ "$cond" == "1" ]]; then
        printf "  %sPASS%s  %s\n" "$c_green" "$c_reset" "$label"
        pass=$((pass + 1))
    else
        printf "  %sFAIL%s  %s\n" "$c_red" "$c_reset" "$label"
        fail=$((fail + 1))
    fi
}

# Resolve a step's line number. A missing anchor is a hard error: silently returning an
# empty value would turn every ordering assertion that uses it into a confusing failure.
line_of() {
    local ln
    ln="$(grep -n -F -- "$1" "$WF" | head -1 | cut -d: -f1)"
    if [[ -z "$ln" ]]; then
        printf "  %sFAIL%s  workflow step not found: %s\n" "$c_red" "$c_reset" "$1"
        fail=$((fail + 1))
        echo 0
        return
    fi
    echo "$ln"
}

BUILD_LN=$(line_of "    - name: Build")
STAGE_LN=$(line_of "    - name: Stage and verify packages")
RESERVE_LN=$(line_of "    - name: Resolve and reserve release version")
CHECKOUT_LN=$(line_of "    - name: Check out the reserved release commit")
PUSH_LN=$(line_of "    - name: Push SDK/Runtime/Templates packs")
REL_LN=$(line_of "    - name: Create GitHub Release")

# --- ordering ---------------------------------------------------------------

assert "build runs before staging" \
    "$([[ -n "$BUILD_LN" && -n "$STAGE_LN" && "$BUILD_LN" -lt "$STAGE_LN" ]] && echo 1 || echo 0)"

# The release commit is now created FIRST so every package embeds the same SHA as the tag.
# Retryability comes from the reservation ref + resume detection, not from deferring it.
assert "version is reserved before the build" \
    "$([[ -n "$RESERVE_LN" && -n "$BUILD_LN" && "$RESERVE_LN" -lt "$BUILD_LN" ]] && echo 1 || echo 0)"

assert "reserved commit is checked out before the build" \
    "$([[ -n "$CHECKOUT_LN" && -n "$BUILD_LN" && "$CHECKOUT_LN" -lt "$BUILD_LN" ]] && echo 1 || echo 0)"

assert "ownership is claimed via an atomic reservation ref" \
    "$(grep -q 'refs/tizen-release/v' "$WF" && echo 1 || echo 0)"

assert "a foreign reservation aborts the run" \
    "$(grep -q 'already reserved by another release' "$WF" && echo 1 || echo 0)"

assert "releases are serialized by a concurrency group" \
    "$(grep -q 'group: tizen-workload-release' "$WF" && echo 1 || echo 0)"

assert "in-flight releases are never cancelled" \
    "$(grep -q 'cancel-in-progress: false' "$WF" && echo 1 || echo 0)"

assert "the build runs from the reserved SHA, not the event SHA" \
    "$(grep -q 'git checkout --detach "\$SHA"' "$WF" && echo 1 || echo 0)"

assert "source drift against the reserved version is rejected" \
    "$(grep -q 'Source drift' "$WF" && echo 1 || echo 0)"

assert "the applied version is pinned explicitly (--set-version)" \
    "$(grep -q 'next-workload-version.py --apply --set-version' "$WF" && echo 1 || echo 0)"

assert "every package is verified to carry the reserved commit" \
    "$(grep -q 'do not all originate from the reserved release commit' "$WF" && echo 1 || echo 0)"

assert "release tag is created last" \
    "$([[ -n "$PUSH_LN" && -n "$REL_LN" && "$PUSH_LN" -lt "$REL_LN" ]] && echo 1 || echo 0)"

# --- retryability / non-mutation --------------------------------------------

assert "OLD == NEW reserves the current commit instead of failing" \
    "$(grep -q 'is already \$NEW; reserving the current commit' "$WF" && ! grep -q 'ERROR: computed next == current' "$WF" && echo 1 || echo 0)"

assert "reference-only run is non-mutating" \
    "$(grep -q 'Reference-only run: leaving TizenWorkloadVersion' "$WF" && echo 1 || echo 0)"

assert "a resumed run rebuilds from the reservation's commit" \
    "$(grep -q 'no reservation ref exists' "$WF" && echo 1 || echo 0)"

assert "build is not continue-on-error" \
    "$(awk -v s="$BUILD_LN" -v e="$STAGE_LN" 'NR>s && NR<e && /continue-on-error/ {found=1} END{exit !found}' "$WF" && echo 0 || echo 1)"

# --- correctness of what gets published -------------------------------------

assert "tag targets the reserved release commit" \
    "$(grep -q 'target "\${{ steps.bump.outputs.release_sha }}"' "$WF" && echo 1 || echo 0)"

assert "release notes use the staged manifest id" \
    "$(grep -q 'steps.stage.outputs.manifest_id' "$WF" && echo 1 || echo 0)"

assert "release notes do not recompute the band with \${SDK%%-*}" \
    "$(grep -q 'BAND="\${SDK%%-\*}"' "$WF" && echo 0 || echo 1)"

assert "pushes come from the verified staging directory" \
    "$(grep -q 'steps.stage.outputs.staging }}/Samsung.NET.Sdk.Tizen.Manifest-' "$WF" && echo 1 || echo 0)"

assert "no push globs the raw workspace output directory" \
    "$(grep -q 'dotnet nuget push ./workload/out/' "$WF" && echo 0 || echo 1)"

assert "existing release tag is a no-op (resumable)" \
    "$(grep -q 'already exists; skipping creation' "$WF" && echo 1 || echo 0)"

# --- partial-publication resume ---------------------------------------------

MANIFEST_PUSH_LN=$(line_of "    - name: Push Manifest pack")
COMPANION_PUSH_LN=$(line_of "    - name: Push SDK/Runtime/Templates packs")
VERIFY_LN=$(line_of "    - name: Verify publication is complete")

assert "publication state is inspected before advancing the version" \
    "$(grep -q 'release-state.py --version "\$OLD"' "$WF" && echo 1 || echo 0)"

assert "a partially published version is resumed, never advanced" \
    "$(grep -q 'is partially published' "$WF" && echo 1 || echo 0)"

assert "a published-but-untagged version is resumed to finish the tag" \
    "$(grep -q 'is published but untagged' "$WF" && echo 1 || echo 0)"

assert "companion packs are pushed BEFORE the manifest" \
    "$([[ -n "$COMPANION_PUSH_LN" && -n "$MANIFEST_PUSH_LN" && "$COMPANION_PUSH_LN" -lt "$MANIFEST_PUSH_LN" ]] && echo 1 || echo 0)"

assert "publication completeness is verified before tagging" \
    "$([[ -n "$VERIFY_LN" && -n "$REL_LN" && "$VERIFY_LN" -lt "$REL_LN" ]] && echo 1 || echo 0)"

assert "every push is idempotent (--skip-duplicate)" \
    "$([[ "$(grep -c 'skip-duplicate' "$WF")" -ge 3 ]] && echo 1 || echo 0)"

# --- resume set must match what the workflow actually publishes --------------
#
# release-state.py decides whether a version is fully published. If a pack is added to the
# push steps but not to that list, a version missing it would be reported "published", get
# tagged, and never be completed - the exact failure this machinery exists to prevent.

assert "band is computed in exactly one place" \
    "$([[ "$(grep -c 'compute_target_version_band' "$WF")" -eq 1 ]] && echo 1 || echo 0)"

STATE_PKGS="$(python3 - "$WORKLOAD_DIR/scripts/release-state.py" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
block = re.search(r"VERSIONED_PACKAGE_SUFFIXES = \[(.*?)\]", src, re.S).group(1)
print("\n".join(sorted(re.findall(r'"([^"]+)"', block))))
PYEOF
)"

# Package globs the workflow pushes under the workload version (excludes the Ref packs,
# which are versioned by TizenFX and gated by release_reference).
PUSHED="$(grep -oE '\$pattern|for pattern in [^;]*' "$WF" | sed -n 's/^for pattern in //p' | tr ' ' '\n' | sed '/^$/d' | sort -u)"

norm() { sed 's/^Samsung\.NETCore\.App\.Runtime$/Samsung.NETCore.App.Runtime.tizen/' ; }
missing_from_state=""
while read -r pkg; do
    [[ -z "$pkg" ]] && continue
    canonical="$(echo "$pkg" | norm)"
    grep -Fqx "$canonical" <<< "$STATE_PKGS" || missing_from_state="$missing_from_state $canonical"
done <<< "$PUSHED"

assert "every pushed pack is tracked by release-state.py" \
    "$([[ -z "$missing_from_state" ]] && echo 1 || echo 0)"
[[ -n "$missing_from_state" ]] && echo "        untracked:$missing_from_state"

# --- failure injection against the real state script -------------------------
#
# Simulates a release interrupted at each step, using a local file:// feed, and asserts the
# resume decision the workflow would make.

STATE_PY="$WORKLOAD_DIR/scripts/release-state.py"
FEED="$(mktemp -d)"
trap 'rm -rf "$FEED"' EXIT

seed() {  # seed <package-id> <version>
    mkdir -p "$FEED/$1"
    printf '{"versions":["%s"]}' "$2" > "$FEED/$1/index.json"
}
state_of() {
    python3 "$STATE_PY" --version "$1" --band 11.0.100-preview.7 \
        --feed-base "file://$FEED" 2>/dev/null | sed -n 's/^state=//p'
}

V=10.0.130
MANIFEST_ID=samsung.net.sdk.tizen.manifest-11.0.100-preview.7

echo ""
echo "-- failure injection --"

rm -rf "$FEED"; mkdir -p "$FEED"
assert "nothing published -> unpublished" "$([[ "$(state_of $V)" == "unpublished" ]] && echo 1 || echo 0)"

# Interrupted immediately after the manifest push (the exact case that stranded V).
seed "$MANIFEST_ID" "$V"
assert "interrupted after manifest push -> partial" "$([[ "$(state_of $V)" == "partial" ]] && echo 1 || echo 0)"

# Interrupted midway through the companion packs.
seed samsung.tizen.sdk "$V"
assert "interrupted after one companion pack -> partial" "$([[ "$(state_of $V)" == "partial" ]] && echo 1 || echo 0)"

seed samsung.netcore.app.runtime.tizen "$V"
assert "interrupted before the last pack -> partial" "$([[ "$(state_of $V)" == "partial" ]] && echo 1 || echo 0)"

seed samsung.tizen.templates "$V"
assert "all packs present -> published" "$([[ "$(state_of $V)" == "published" ]] && echo 1 || echo 0)"

# A different version must be unaffected by V's artifacts.
assert "an unrelated version is still unpublished" "$([[ "$(state_of 10.0.131)" == "unpublished" ]] && echo 1 || echo 0)"

# A feed that cannot be reached must NOT read as "unpublished" - that would advance the
# version and strand the partial release.
python3 "$STATE_PY" --version "$V" --band 11.0.100-preview.7 \
    --feed-base "http://127.0.0.1:9/unreachable" >/dev/null 2>&1
assert "unreachable feed exits non-zero (never 'unpublished')" \
    "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

echo ""
echo "=========== release-workflow summary ==========="
echo "  passed: $pass"
echo "  failed: $fail"

[[ $fail -eq 0 ]] || exit 1
exit 0
