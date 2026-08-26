#!/bin/bash
#
# Copyright (c) Samsung Electronics. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Unit test for the SDK feature-band detection used by the install scripts.
#
# The band string decides three things at install time:
#   * the NuGet package id     Samsung.NET.Sdk.Tizen.Manifest-<band>
#   * the manifest directory   <dotnet>/sdk-manifests/<band>/samsung.net.sdk.tizen
#   * the version-map key      $MANIFEST_BASE_NAME-<band>
# Getting it wrong silently installs the workload where the SDK will never look,
# so it is worth a real test — especially for new majors such as .NET 11 preview.
#
# The bash implementation is extracted from workload-install.sh between the
# "BEGIN/END VERSION BAND DETECTION" markers so the test always exercises the
# shipped code rather than a copy.
#
# Usage:
#   bash workload/scripts/test-version-band.sh
#   make -C workload test-version-band
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SH_SCRIPT="$SCRIPT_DIR/workload-install.sh"
PS1_SCRIPT="$SCRIPT_DIR/workload-install.ps1"

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'
[[ -t 1 ]] || { c_reset=""; c_red=""; c_green=""; }

# --- load the function under test ------------------------------------------

if [[ ! -f "$SH_SCRIPT" ]]; then
    echo "ERROR: $SH_SCRIPT not found."
    exit 2
fi

BAND_FUNC="$(sed -n '/# BEGIN VERSION BAND DETECTION/,/# END VERSION BAND DETECTION/p' "$SH_SCRIPT")"
if [[ -z "$BAND_FUNC" ]]; then
    echo "ERROR: VERSION BAND DETECTION markers not found in $SH_SCRIPT."
    echo "       The install script was edited without keeping the markers intact."
    exit 2
fi
eval "$BAND_FUNC"

# --- cases: "<sdk version>|<expected band>" --------------------------------
CASES=(
    # .NET 6 has no preview bands: always rounded to the feature band.
    "6.0.419|6.0.400"
    "6.0.100|6.0.100"
    # Stable bands.
    "7.0.400|7.0.400"
    "8.0.404|8.0.400"
    "9.0.304|9.0.300"
    "10.0.100|10.0.100"
    "10.0.400|10.0.400"
    # Pre-release bands.
    "7.0.100-preview.6.22352.1|7.0.100-preview.6"
    "8.0.100-rc.2.23502.2|8.0.100-rc.2"
    "8.0.100-rtm.23512.16|8.0.100-rtm"
    "9.0.100-alpha.1.23615.4|9.0.100-alpha.1"
    "10.0.100-rc.2.25502.107|10.0.100-rc.2"
    # .NET 11 — the band this repo now supports.
    "11.0.100-preview.7.26381.103|11.0.100-preview.7"
    "11.0.100-preview.6.26359.118|11.0.100-preview.6"
    "11.0.100-rc.1.26500.1|11.0.100-rc.1"
    "11.0.100|11.0.100"
    "11.0.200|11.0.200"
    # Future majors must keep working without another code change.
    "12.0.100-preview.1.27000.1|12.0.100-preview.1"
)

pass=0; fail=0

for case in "${CASES[@]}"; do
    version="${case%%|*}"
    expected="${case##*|}"
    actual="$(compute_target_version_band "$version")"
    if [[ "$actual" == "$expected" ]]; then
        printf "  %sPASS%s  %-32s -> %s\n" "$c_green" "$c_reset" "$version" "$actual"
        pass=$((pass + 1))
    else
        printf "  %sFAIL%s  %-32s -> %s (expected %s)\n" "$c_red" "$c_reset" "$version" "$actual" "$expected"
        fail=$((fail + 1))
    fi
done

# --- parity check: the PowerShell installer must agree ---------------------
#
# workload-install.ps1 reimplements the same logic. Run the same cases through
# pwsh when it is available so the two installers cannot drift apart.

if command -v pwsh >/dev/null 2>&1 && [[ -f "$PS1_SCRIPT" ]]; then
    echo ""
    echo "-- PowerShell parity --"
    for case in "${CASES[@]}"; do
        version="${case%%|*}"
        expected="${case##*|}"
        actual="$(pwsh -NoProfile -Command "
            \$DotnetVersion = '$version'
            \$VersionSplitSymbol = '.'
            \$SplitVersion = \$DotnetVersion.Split(\$VersionSplitSymbol)
            \$CurrentDotnetVersion = [Version]\"\$(\$SplitVersion[0]).\$(\$SplitVersion[1])\"
            \$DotnetVersionBand = \$SplitVersion[0] + \$VersionSplitSymbol + \$SplitVersion[1] + \$VersionSplitSymbol + \$SplitVersion[2][0] + '00'
            \$DotnetTargetVersionBand = \$DotnetVersionBand
            if (\$CurrentDotnetVersion -ge [Version]'7.0') {
                \$IsPreviewVersion = \$DotnetVersion.Contains('-preview') -or \$DotnetVersion.Contains('-rc') -or \$DotnetVersion.Contains('-alpha')
                if (\$IsPreviewVersion -and (\$SplitVersion.Count -ge 4)) {
                    \$DotnetTargetVersionBand = \$DotnetVersionBand + \$SplitVersion[2].SubString(3) + \$VersionSplitSymbol + \$(\$SplitVersion[3])
                }
                elseif (\$DotnetVersion.Contains('-rtm') -and (\$SplitVersion.Count -ge 3)) {
                    \$DotnetTargetVersionBand = \$DotnetVersionBand + \$SplitVersion[2].SubString(3)
                }
            }
            Write-Output \$DotnetTargetVersionBand" 2>/dev/null | tr -d '\r')"
        if [[ "$actual" == "$expected" ]]; then
            printf "  %sPASS%s  %-32s -> %s\n" "$c_green" "$c_reset" "$version" "$actual"
            pass=$((pass + 1))
        else
            printf "  %sFAIL%s  %-32s -> %s (expected %s)\n" "$c_red" "$c_reset" "$version" "$actual" "$expected"
            fail=$((fail + 1))
        fi
    done
else
    echo ""
    echo "  (pwsh not available - skipping workload-install.ps1 parity check)"
fi

echo ""
echo "================ version-band summary ================"
echo "  passed: $pass"
echo "  failed: $fail"

[[ $fail -eq 0 ]] || exit 1
exit 0
