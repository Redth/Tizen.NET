#!/bin/bash
#
# Copyright (c) Samsung Electronics. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Evaluation regression test for the Tizen template's platform-version detection.
#
# The template conditions its Tizen.UI.Components.Material PackageReference on the Tizen
# platform band. PackageReference items are evaluated with the project body, which runs
# BEFORE the .NET SDK infers $(TargetPlatformVersion) from the TFM — so the detection must
# parse $(TargetFramework) itself. Reading $(TargetPlatformVersion) in the body silently
# yields an empty string and falls back to the default, which wrongly pulls Material into
# e.g. net11.0-tizen9.0 and suppresses TIZENTMPL001.
#
# This test extracts the real PropertyGroup from the shipped template csproj (between the
# BEGIN/END TIZEN UI PLATFORM DETECTION markers) and evaluates it against a table of TFMs.
# Extracting rather than duplicating means the test cannot drift from what ships, and it
# needs no Tizen workload — so it runs in the metadata CI job.
#
# Usage:
#   bash workload/scripts/test-template-conditions.sh
#   make -C workload test-template-conditions
#
# Environment overrides:
#   DOTNET   path to the dotnet command (default: dotnet from PATH)
#

set -uo pipefail

WORKLOAD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CSPROJ="$WORKLOAD_DIR/src/Samsung.Tizen.Templates/tizen/TizenApp1.csproj"
DOTNET="${DOTNET:-dotnet}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
[[ -t 1 ]] || { c_reset=""; c_red=""; c_green=""; c_yellow=""; }

if ! command -v "$DOTNET" >/dev/null 2>&1; then
    echo "  ${c_yellow}SKIP${c_reset}  '$DOTNET' not found; cannot evaluate MSBuild expressions."
    exit 0
fi

if [[ ! -f "$CSPROJ" ]]; then
    echo "ERROR: template csproj not found at $CSPROJ"
    exit 2
fi

DETECTION="$(sed -n '/BEGIN TIZEN UI PLATFORM DETECTION/,/END TIZEN UI PLATFORM DETECTION/p' "$CSPROJ" \
             | sed -n '/<PropertyGroup>/,/<\/PropertyGroup>/p')"

if [[ -z "$DETECTION" ]]; then
    echo "ERROR: TIZEN UI PLATFORM DETECTION markers (or the PropertyGroup between them)"
    echo "       not found in $CSPROJ. Keep the markers intact so this test stays honest."
    exit 2
fi

# Build a probe project containing the extracted PropertyGroup verbatim.
{
    echo '<Project>'
    echo "$DETECTION"
    echo '  <Target Name="Probe">'
    echo '    <Message Importance="high" Text="RESULT|$(_TizenUIPlatformVersion)|$(_TizenUIMaterialSupported)" />'
    echo '  </Target>'
    echo '</Project>'
} > "$TMPDIR/probe.proj"

# Cases: "<TargetFramework>|<expected platform version>|<expected material supported>"
CASES=(
    # Below the Material floor: must NOT reference Material.
    "net11.0-tizen8.0|8.0|False"
    "net11.0-tizen9.0|9.0|False"
    "net10.0-tizen8.0|8.0|False"
    "net8.0-tizen9.0|9.0|False"
    # At or above the floor: Material is referenced.
    "net11.0-tizen10.0|10.0|True"
    "net11.0-tizen10.1|10.1|True"
    "net11.0-tizen11.0|11.0|True"
    "net10.0-tizen10.0|10.0|True"
    "net8.0-tizen11.0|11.0|True"
    # Unversioned / outer multi-targeting build: assume the SDK default (10.0).
    "net11.0-tizen|10.0|True"
    "net10.0-tizen|10.0|True"
    "|10.0|True"
    # A non-Tizen TFM must not be misparsed.
    "net10.0|10.0|True"
)

pass=0; fail=0

for case in "${CASES[@]}"; do
    IFS='|' read -r tfm want_ver want_mat <<< "$case"

    out="$("$DOTNET" msbuild "$TMPDIR/probe.proj" -t:Probe -nologo -v:m \
            -p:TargetFramework="$tfm" 2>&1 | grep -o 'RESULT|[^|]*|[^ ]*' | head -1)"
    got_ver="$(echo "$out" | cut -d'|' -f2)"
    got_mat="$(echo "$out" | cut -d'|' -f3)"

    label="${tfm:-<empty>}"
    if [[ "$got_ver" == "$want_ver" && "$got_mat" == "$want_mat" ]]; then
        printf "  %sPASS%s  %-22s -> platform=%-5s material=%s\n" \
            "$c_green" "$c_reset" "$label" "$got_ver" "$got_mat"
        pass=$((pass + 1))
    else
        printf "  %sFAIL%s  %-22s -> platform=%-5s material=%-5s (expected %s / %s)\n" \
            "$c_red" "$c_reset" "$label" "${got_ver:-?}" "${got_mat:-?}" "$want_ver" "$want_mat"
        fail=$((fail + 1))
    fi
done

echo ""
echo "============ template-conditions summary ============"
echo "  passed: $pass"
echo "  failed: $fail"

[[ $fail -eq 0 ]] || exit 1
exit 0
