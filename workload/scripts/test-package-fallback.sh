#!/bin/bash
#
# Copyright (c) Samsung Electronics. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Evaluation test for PackageTargetFallback compatibility filtering.
#
# FixupNuGetReferences matches a package's lib/<name>/ sibling directories against
# PackageTargetFallback by NAME ONLY - it performs no compatibility check of its own.
# An unfiltered cross-product therefore lets a net6.0-tizen8.0 build silently pick up
# net6.0-tizen11.0 (newer platform) or net11.0-tizen8.0 (newer .NET) assets.
#
# This test extracts the real filtering block from the shipped
# Samsung.Tizen.Sdk.NuGet.targets (between the BEGIN/END TIZEN PACKAGE FALLBACK markers)
# and evaluates it, asserting both that compatible entries are present and - the point of
# the exercise - that incompatible ones are ABSENT.
#
# Usage:
#   bash workload/scripts/test-package-fallback.sh
#   make -C workload test-package-fallback
#

set -uo pipefail

WORKLOAD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS="$WORKLOAD_DIR/src/Samsung.Tizen.Sdk/targets/Samsung.Tizen.Sdk.NuGet.targets"
DOTNET="${DOTNET:-dotnet}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
[[ -t 1 ]] || { c_reset=""; c_red=""; c_green=""; c_yellow=""; }

if ! command -v "$DOTNET" >/dev/null 2>&1; then
    echo "  ${c_yellow}SKIP${c_reset}  '$DOTNET' not found; cannot evaluate MSBuild expressions."
    exit 0
fi

BLOCK="$(sed -n '/BEGIN TIZEN PACKAGE FALLBACK/,/END TIZEN PACKAGE FALLBACK/p' "$TARGETS" \
         | sed -e '1d' -e '$d')"
if [[ -z "$BLOCK" ]]; then
    echo "ERROR: TIZEN PACKAGE FALLBACK markers not found in $TARGETS."
    echo "       Keep the markers intact so this test exercises shipped code."
    exit 2
fi

{
    echo '<Project>'
    echo "$BLOCK"
    echo '  <Target Name="Probe">'
    echo '    <Message Importance="high" Text="RESULT|$(PackageTargetFallback)" />'
    echo '  </Target>'
    echo '</Project>'
} > "$TMPDIR/probe.proj"

pass=0; fail=0

# "<TFV>|<TPV>|<must be present, comma-sep>|<must be ABSENT, comma-sep>"
CASES=(
    # Building for the lowest supported platform: nothing newer may leak in.
    "v6.0|8.0|net6.0-tizen8.0,tizen80|net6.0-tizen9.0,net6.0-tizen10.0,net6.0-tizen11.0,net8.0-tizen8.0,net11.0-tizen11.0,tizen90,tizen10.0"
    # Newer .NET, old platform: platform siblings above 8.0 must stay out.
    "v11.0|8.0|net11.0-tizen8.0,net6.0-tizen8.0,tizen80|net11.0-tizen9.0,net6.0-tizen11.0,net11.0-tizen11.0,tizen90"
    # Old .NET, newest platform: .NET majors above 6.0 must stay out.
    "v6.0|11.0|net6.0-tizen11.0,net6.0-tizen8.0,tizen10.0|net8.0-tizen11.0,net11.0-tizen11.0,net9.0-tizen10.0"
    # The primary target: everything at or below is fair game.
    "v11.0|11.0|net11.0-tizen11.0,net6.0-tizen8.0,net8.0-tizen10.0,tizen40|"
    # Mid-range combination.
    "v9.0|10.0|net9.0-tizen10.0,net8.0-tizen9.0,tizen10.0|net10.0-tizen10.0,net11.0-tizen11.0,net9.0-tizen10.1,net9.0-tizen11.0"
    # 10.1 must not admit 11.0, and 10.1 itself is available at 10.1.
    "v10.0|10.1|net10.0-tizen10.1,net10.0-tizen10.0|net10.0-tizen11.0,net11.0-tizen10.1"
)

for case in "${CASES[@]}"; do
    IFS='|' read -r tfv tpv want_present want_absent <<< "$case"

    out="$("$DOTNET" msbuild "$TMPDIR/probe.proj" -t:Probe -nologo -v:m \
            -p:TargetFrameworkVersion="$tfv" -p:TargetPlatformVersion="$tpv" 2>&1 \
            | grep -o 'RESULT|.*' | head -1)"
    list=";${out#RESULT|};"
    list="${list// /}"

    label="net${tfv#v}-tizen${tpv}"
    row_ok=1
    detail=""

    presents=(); absents=()
    [[ -n "$want_present" ]] && IFS=',' read -ra presents <<< "$want_present"
    [[ -n "$want_absent"  ]] && IFS=',' read -ra absents  <<< "$want_absent"

    for e in "${presents[@]+"${presents[@]}"}"; do
        [[ -z "$e" || "$e" == *_SKIP ]] && continue
        if [[ "$list" != *";$e;"* ]]; then row_ok=0; detail="$detail missing:$e"; fi
    done

    for e in "${absents[@]+"${absents[@]}"}"; do
        [[ -z "$e" ]] && continue
        if [[ "$list" == *";$e;"* ]]; then row_ok=0; detail="$detail LEAKED:$e"; fi
    done

    if [[ $row_ok -eq 1 ]]; then
        printf "  %sPASS%s  %-22s\n" "$c_green" "$c_reset" "$label"
        pass=$((pass + 1))
    else
        printf "  %sFAIL%s  %-22s%s\n" "$c_red" "$c_reset" "$label" "$detail"
        printf "        list: %s\n" "${out#RESULT|}"
        fail=$((fail + 1))
    fi
done

echo ""
echo "=========== package-fallback summary ==========="
echo "  passed: $pass"
echo "  failed: $fail"

[[ $fail -eq 0 ]] || exit 1
exit 0
