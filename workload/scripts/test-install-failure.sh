#!/bin/bash
#
# Copyright (c) Samsung Electronics. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Exit-code regression test for the install scripts.
#
# Both installers used to swallow every per-SDK failure: install_tizenworkload returned
# early on error, the caller ignored the result, and the script printed "DONE" and exited 0.
# A CI job that pipes the script to bash therefore reported success even when nothing was
# installed. These tests pin the corrected behaviour.
#
# Usage:
#   bash workload/scripts/test-install-failure.sh
#   make -C workload test-install-failure
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SH_SCRIPT="$SCRIPT_DIR/workload-install.sh"
PS1_SCRIPT="$SCRIPT_DIR/workload-install.ps1"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
[[ -t 1 ]] || { c_reset=""; c_red=""; c_green=""; c_yellow=""; }

pass=0; fail=0

check() {
    local name="$1" expected="$2" actual="$3" output="$4"
    if [[ "$actual" == "$expected" ]]; then
        printf "  %sPASS%s  %-52s exit=%s\n" "$c_green" "$c_reset" "$name" "$actual"
        pass=$((pass + 1))
    else
        printf "  %sFAIL%s  %-52s exit=%s (expected %s)\n" "$c_red" "$c_reset" "$name" "$actual" "$expected"
        echo "$output" | tail -6 | sed 's/^/        | /'
        fail=$((fail + 1))
    fi
}

# --- 1. missing dotnet install dir must fail ------------------------------------

out="$(bash "$SH_SCRIPT" -d "$TMPROOT/does-not-exist" 2>&1)"; rc=$?
check "sh: nonexistent --dotnet-install-dir" 1 "$rc" "$out"

# --- 2. dotnet present but no manifest for the band must fail -------------------
#
# A stub dotnet reports an implausible SDK version. The band lookup finds nothing on
# NuGet and nothing in the fallback version map, so install_tizenworkload must fail and
# the script must exit non-zero instead of printing DONE.

FAKE="$TMPROOT/fakedotnet"
mkdir -p "$FAKE"
cat > "$FAKE/dotnet" <<'STUB'
#!/bin/bash
case "$1" in
    --version)    echo "99.0.100" ;;
    --list-sdks)  echo "99.0.100 [$(dirname "$0")/sdk]" ;;
    *)            exit 0 ;;
esac
STUB
chmod +x "$FAKE/dotnet"

if curl -sSf -m 20 -o /dev/null https://api.nuget.org/v3/index.json 2>/dev/null; then
    out="$(cd "$TMPROOT" && bash "$SH_SCRIPT" -d "$FAKE" 2>&1)"; rc=$?
    check "sh: unknown SDK band fails instead of printing DONE" 1 "$rc" "$out"

    if grep -q "^DONE$" <<< "$out"; then
        printf "  %sFAIL%s  %-52s\n" "$c_red" "$c_reset" "sh: must not print DONE on failure"
        fail=$((fail + 1))
    else
        printf "  %sPASS%s  %-52s\n" "$c_green" "$c_reset" "sh: must not print DONE on failure"
        pass=$((pass + 1))
    fi
else
    printf "  %sSKIP%s  %-52s (no network)\n" "$c_yellow" "$c_reset" "sh: unknown SDK band"
fi

# --- 3. PowerShell parity ------------------------------------------------------

if command -v pwsh >/dev/null 2>&1 && [[ -f "$PS1_SCRIPT" ]]; then
    out="$(pwsh -NoProfile -File "$PS1_SCRIPT" -d "$TMPROOT/does-not-exist" 2>&1)"; rc=$?
    check "ps1: nonexistent -DotnetInstallDir" 1 "$rc" "$out"
else
    printf "  %sSKIP%s  %-52s (pwsh unavailable)\n" "$c_yellow" "$c_reset" "ps1 parity"
fi

echo ""
echo "============= install-failure summary ============="
echo "  passed: $pass"
echo "  failed: $fail"

[[ $fail -eq 0 ]] || exit 1
exit 0
