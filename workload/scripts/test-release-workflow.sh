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

line_of() { grep -n -- "$1" "$WF" | head -1 | cut -d: -f1; }

BUILD_LN=$(line_of "    - name: Build")
STAGE_LN=$(line_of "    - name: Stage and verify packages")
COMMIT_LN=$(line_of "    - name: Commit and push the version bump")
PUSH_LN=$(line_of "    - name: Push Manifest/SDK/Runtime packs")
REL_LN=$(line_of "    - name: Create GitHub Release")

# --- ordering ---------------------------------------------------------------

assert "build runs before staging" \
    "$([[ -n "$BUILD_LN" && -n "$STAGE_LN" && "$BUILD_LN" -lt "$STAGE_LN" ]] && echo 1 || echo 0)"

assert "version bump is persisted AFTER staging verification" \
    "$([[ -n "$STAGE_LN" && -n "$COMMIT_LN" && "$STAGE_LN" -lt "$COMMIT_LN" ]] && echo 1 || echo 0)"

assert "version bump is persisted BEFORE packages are pushed" \
    "$([[ -n "$COMMIT_LN" && -n "$PUSH_LN" && "$COMMIT_LN" -lt "$PUSH_LN" ]] && echo 1 || echo 0)"

assert "release tag is created last" \
    "$([[ -n "$PUSH_LN" && -n "$REL_LN" && "$PUSH_LN" -lt "$REL_LN" ]] && echo 1 || echo 0)"

# --- retryability / non-mutation --------------------------------------------

assert "OLD == NEW resumes instead of aborting" \
    "$(grep -q 'Resuming release of' "$WF" && ! grep -q 'ERROR: computed next == current' "$WF" && echo 1 || echo 0)"

assert "reference-only run is non-mutating" \
    "$(grep -q 'Reference-only run: leaving TizenWorkloadVersion' "$WF" && echo 1 || echo 0)"

assert "commit step is skipped when nothing was mutated" \
    "$(grep -q 'steps.bump.outputs.mutated' "$WF" && echo 1 || echo 0)"

assert "build is not continue-on-error" \
    "$(awk -v s="$BUILD_LN" -v e="$STAGE_LN" 'NR>s && NR<e && /continue-on-error/ {found=1} END{exit !found}' "$WF" && echo 0 || echo 1)"

# --- correctness of what gets published -------------------------------------

assert "tag targets the released commit, not just the branch ref" \
    "$(grep -q 'steps.commit.outputs.release_sha' "$WF" && echo 1 || echo 0)"

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

echo ""
echo "=========== release-workflow summary ==========="
echo "  passed: $pass"
echo "  failed: $fail"

[[ $fail -eq 0 ]] || exit 1
exit 0
