# .NET 11 support

This branch builds the `tizen` workload for the .NET 11 SDK band in addition to .NET 10.

At the time of writing .NET 11 is in **preview**: the newest SDK is
`11.0.100-preview.7.26381.103` (released 2026-08-11). Everything below therefore describes a
band that is real and buildable, but whose manifest package has **not been published to
nuget.org yet**.

## TFM and API mapping

The primary target framework is **`net11.0-tizen11.0`**.

| Tizen platform version | TizenFX API level | Targeting (ref) pack | Pack version |
|---|---|---|---|
| `tizen8.0`  | 11 | `Samsung.Tizen.Ref.API11` | `$(TizenFXAPI11Version)` |
| `tizen9.0`  | 12 | `Samsung.Tizen.Ref.API12` | `$(TizenFXAPI12Version)` |
| `tizen10.0` | 13 | `Samsung.Tizen.Ref.API13` | `$(TizenFXAPI13Version)` |
| `tizen10.1` | 14 | `Samsung.Tizen.Ref.API14` | `$(TizenFXAPI14Version)` |
| **`tizen11.0`** | **15** | **`Samsung.Tizen.Ref.API15`** | `$(TizenFXAPI15Version)` |

The .NET version axis and the Tizen platform axis are independent, so `net11.0` combines with
every platform version above — `net11.0-tizen8.0` … `net11.0-tizen11.0` are all valid. The
`tizen-manifest.xml` `api-version` attribute must match the platform version
(`tizen11.0` → `api-version="11"`, `tizen10.1` → `10.1`, `tizen10.0` → `10`).

**No new reference pack is required for .NET 11.** Ref packs ship reference assemblies under
`ref/net8.0/` and are resolved by explicit `<File Path="…"/>` entries in `data/FrameworkList.xml`,
so they are independent of the consuming project's .NET version. `Samsung.Tizen.Ref.API16` does
not exist and is not needed.

Use versioned TFMs. The unversioned `net11.0-tizen` form is still accepted as project input but
resolves to `_DefaultTargetPlatformVersion` (`10.0`), which is rarely what a caller wants.

## Building the .NET 11 band

`DOTNET_VERSION` selects the SDK band; it defaults to
`MicrosoftDotnetSdkInternalPackageVersion` in `build/Versions.props` (currently the .NET 10 band).

```sh
# Produce the packs, including Samsung.NET.Sdk.Tizen.Manifest-11.0.100-preview.7
make packs DOTNET_VERSION=11.0.100-preview.7.26381.103

# Install into the locally bootstrapped SDK and run the full TFM matrix
make test-matrix DOTNET_VERSION=11.0.100-preview.7.26381.103
```

The exact SDK version CI uses lives in `build/Versions.props` as `<DotNet11SdkVersion>`.
That property is the single source of truth: the workflows grep it, so bumping the preview
there is enough. `validate-workload-metadata.py` check C7 fails if a workflow hardcodes a
different `11.0.1xx-*` version.

The band string is derived generically from `DOTNET_VERSION`, so `11.0.100-rc.1.*` and the
eventual `11.0.100` GA need no further code change. This is asserted by
[`scripts/test-version-band.sh`](../scripts/test-version-band.sh).

## CI behaviour

| Branch / PR target | .NET 10 matrix leg | .NET 11 matrix leg | `Build Workload` SDK |
|---|---|---|---|
| `main`, `net10.0` | blocking | advisory (`continue-on-error`) | Versions.props default (.NET 10) |
| `net11.0` | blocking | **blocking** | **`$(DotNet11SdkVersion)`** |

.NET 11 is advisory only while the branch ships a different band. On a `net11.0` branch
.NET 11 *is* the product, so both the matrix leg and the workload build switch to it.

## Local checks

`make check` runs everything that needs no dotnet install or Tizen workload:

| Target | What it pins |
|---|---|
| `validate-metadata` | C1–C8 cross-file consistency |
| `test-matrix-self-test` | matrix row selection (an over-strict check silently builds nothing) |
| `test-version-band` | SDK version → feature band across **both installers and Config.mk**, fallback band family, band isolation |
| `test-template-conditions` | template platform detection across TFMs |
| `test-install-failure` | installers exit non-zero on failure |
| `Generate-InstallScripts.ps1 -Check` | version-map drift **and** install-script integrity |

`make check` requires `pwsh` for the last row. If it is unavailable the target fails with an
actionable message; `make check SKIP_PWSH_CHECKS=1` proceeds with those checks unverified.

## Band isolation and feature-band rounding

`DOTNET_VERSION` is resolved immediately in `Config.mk`, and `DOTNET_DESTDIR` plus the install
stamp are scoped by band (`out/dotnet-<band>`, `.stamp-install-workload-<band>`). Two
consequences worth knowing:

- Building a different band in an existing tree bootstraps a separate SDK instead of reusing
  the previous one. Previously `DOTNET_VERSION` was cached in `.tmp/dotnet-version.config`
  whose only prerequisite was `Versions.props`; because the cache was newer, make never
  regenerated it and a newly-passed `DOTNET_VERSION` was **ignored**, silently building and
  testing the previous band.
- Feature bands round the patch component down: `10.0.404` → `10.0.400`, `9.0.304` → `9.0.300`.
  `Config.mk` previously did not round for stable non-6 versions, so it produced band
  `10.0.404` while the installers looked for `10.0.400` — the manifest was installed where the
  SDK would never look. `test-version-band.sh` now asserts producer/consumer agreement.

Pass `DOTNET_VERSION` via the environment or omit it. An explicit empty command-line override
(`make DOTNET_VERSION=`) beats the resolved value and yields an empty band.

## Package asset resolution

`PackageTargetFallback` in `Samsung.Tizen.Sdk.NuGet.targets` lists the package `lib/<tfm>/`
folder names that `FixupNuGetReferences` prefers over a package's `netstandard2.x` assets. A
combination missing from that list means a package shipping both `lib/netstandard2.0/` and
`lib/<tfm>/` silently resolves to the **netstandard** assembly. It now covers the full
(.NET major × Tizen platform) cross-product — including `net11.0-tizen11.0` — and check C8
keeps it in sync with `KnownRuntimePack` × `TizenSdkSupportedTargetPlatformVersion`.

## Manifest fallback safety

When a band's manifest is not published, the installers fall back to the cached version map.
That fallback is now constrained to the **same .NET major.minor family**. The PowerShell
installer previously took a fixed-length prefix (`$ManifestBaseName.Length + 2`), so
`...Manifest-11.0.100-preview.7` was truncated to `...Manifest-1`, matched the 10.x entries and
installed a **.NET 10 manifest into an 11.x band**. An 11.x request with no 11.x map entry now
fails closed.

## What changed in this repository

| File | Change |
|---|---|
| `build/Versions.props` | `MicrosoftDotNetBuildTasksFeedPackageVersion` = `11.0.0-beta.26426.103` when building an `11.0` band |
| `NuGet.config` | added the `dotnet11` package source |
| `src/Samsung.Tizen.Sdk/targets/Samsung.Tizen.Sdk.targets` | added the `net11.0` `KnownRuntimePack` |
| `src/Samsung.NETCore.App.Runtime/data/RuntimeList.xml` | added the `.NET Runtime 11` `FileList` row |
| `src/Samsung.Tizen.Templates/.../template.json` | added the `net11.0` framework choice (default stays `net10.0`) |
| `src/Samsung.Tizen.Templates/tizen/TizenApp1.csproj` | Material referenced conditionally; platform version parsed from the TFM, not `$(TargetPlatformVersion)` (see below) |
| `scripts/test-matrix.sh` | added `net11.0-*` rows; rows are skipped only when newer than the installed SDK; `--self-test` mode |
| `scripts/validate-workload-metadata.py` | new checks C5/C6/C7 |
| `scripts/test-version-band.sh` | new — asserts SDK-version → feature-band mapping for both installers |
| `scripts/test-template-conditions.sh` | new — pins template platform detection across TFMs |
| `scripts/test-install-failure.sh` | new — pins installer exit codes |
| `.github/workflows/build-matrix.yml` | .NET 11 leg, advisory off a `net11.0` branch and blocking on one |
| `.github/workflows/build-workload.yml` | builds against `$(DotNet11SdkVersion)` on a `net11.0` branch |

### Template platform detection

`PackageReference` items are evaluated with the project body, which runs **before** the .NET
SDK infers `$(TargetPlatformVersion)` from the TFM. Reading that property in the body yields an
empty string, so a naive implementation falls back to the default and pulls an incompatible
`Tizen.UI.Components.Material` into e.g. `net11.0-tizen9.0` while never raising `TIZENTMPL001`.
The template therefore parses the platform version out of `$(TargetFramework)` directly, and
re-checks the authoritative `$(TargetPlatformVersion)` inside a target where it is available.
`scripts/test-template-conditions.sh` extracts the shipped `PropertyGroup` and pins the
behaviour across 13 TFMs.

`version-map.json` is deliberately **not** updated. That table is a fallback cache of *already
published* manifest versions, consulted only when the NuGet lookup fails. Adding an entry for a
band that has never been released would make `workload-install.sh` download a 404. The
`11.0.100-preview.7` entry should be added in a follow-up commit *after* the first release, the
same way `10.0.300` was.

## External blockers

These artifacts are owned by other repositories. Nothing in Samsung/Tizen.NET can fix them, and
they are not faked here.

### 1. `Samsung.NET.Sdk.Tizen.Manifest-11.0.100-preview.7` is unpublished

- **Owner:** Samsung/Tizen.NET maintainers (this repo's `Release Workload` workflow).
- **Action:** run `Release Workload` with `net_sdk_version = 11.0.100-preview.7.26381.103`.
- **Until then:** `workload-install.sh` on an 11.x SDK finds no manifest. Local development works
  via `make install DOTNET_VERSION=11.0.100-preview.7.26381.103`, which installs into the
  bootstrapped SDK under `workload/out/dotnet`.

### 2. `Tizen.UIExtensions.NUI` has no modern assets

- **Owner:** [Samsung/Tizen.UIExtensions](https://github.com/Samsung/Tizen.UIExtensions).
- **Published state:** `0.9.2` ships `lib/net6.0-tizen7.0/` and `lib/tizen10.0/`. Source on `main`
  targets `<TargetFrameworks>tizen10.0;net6.0-tizen</TargetFrameworks>` against
  `Tizen.NET 10.0.0.17508` (API level 10).
- **Note:** NuGet TFM compatibility is *not* the problem — `net6.0-tizen7.0` is consumable from
  `net11.0-tizen11.0`. The blocker is the dependency group, which pins
  `Microsoft.Maui.Graphics` / `Microsoft.Maui.Graphics.Skia` `6.0.300-rc.3.1336` and
  `SkiaSharp.Views 2.88.6`, dragging .NET 6-era MAUI Graphics into any modern MAUI build.
- **Expected artifact:** a `Tizen.UIExtensions.NUI` release with a `lib/net11.0-tizen11.0/` folder
  built against `Samsung.Tizen.Ref.API15` and a refreshed `Microsoft.Maui.Graphics*` dependency.
- **API risk, measured:** all types .NET MAUI's Tizen backend needs are present in API 15. Between
  API 11 and API 15, `Tizen.NUI.ScrollView`, `Tizen.NUI.ItemView` (and the `Item*`/`Ruler*`
  families), `Tizen.NUI.Components.Title`, `Tizen.NUI.Adaptor`, `Tizen.NUI.AutofillContainer`,
  `Tizen.NUI.Accessibility.AccessibilityManager`, the `CubeTransition*` effects and the entire
  `Tizen.NUI.Wearable` namespace were removed. Ports should use
  `Tizen.NUI.Components.ScrollableBase`, which is retained.

### 3. `Tizen.UI.Components.Material` is platform-gated

- **Owner:** TizenAPI / Samsung (package `Tizen.UI.Components.Material`).
- **Published state:** `1.0.0-rc.8` ships **only** `lib/net8.0-tizen10.0/`; never went GA.
- **Effect:** consumable from `-tizen10.0`, `-tizen10.1` and `-tizen11.0`, but not from
  `-tizen8.0` / `-tizen9.0`. The `dotnet new tizen` template now references it conditionally and
  raises `TIZENTMPL001` with an actionable message instead of an opaque restore failure when the
  target platform is below `tizen10.0`.
- **Expected artifact:** a release with `lib/` assets for the lower platform bands, or a separate
  non-Material template family for them.

## Notes for release notes
Observations from porting a real consumer (`Samsung/Tizen.UIExtensions`) onto this band:

- **`net6.0-tizen7.0` is no longer reproducible.** `Samsung.Tizen.Sdk` dropped `7.0` from
  `TizenSdkSupportedTargetPlatformVersion` (now `8.0`/`9.0`/`10.0`/`10.1`/`11.0`), so packages
  that historically shipped a `net6.0-tizen7.0` asset cannot rebuild one.
- **Unversioned `net6.0-tizen` now resolves to platform 10.0** (`_DefaultTargetPlatformVersion`),
  i.e. TizenFX API 13, where all of ElmSharp and `Tizen.NUI.Window.Instance` are `[Obsolete]`.
  Consumers building that TFM with `TreatWarningsAsErrors` will break. Use a versioned TFM.
- **`tizen.myget.org` returns HTTP 401 to anonymous clients.** The feed is still referenced as a
  push target in `build-workload.yml`'s deploy job. Any documentation or template still pointing
  consumers at it for *restore* is dead; worth confirming whether the push target is still wanted.

## `RuntimeList.xml` is not XML-parsed (investigated)

`src/Samsung.NETCore.App.Runtime/data/RuntimeList.xml` contains one `<FileList .../>` element per
supported .NET version and therefore has multiple root elements, i.e. it is **not well-formed
XML**. This is pre-existing and deliberate-by-accident: `Samsung.NETCore.App.Runtime.tizen` is a
placeholder runtime pack (its only payload is `lib/net6.0-tizen/_._`), and the file is never
parsed.

Verified against the .NET 11 SDK by replacing the installed pack's `RuntimeList.xml` with the
literal text `<<< THIS IS NOT XML AT ALL &&& >>>` and rebuilding a `net11.0-tizen11.0` project
**with an explicit `RuntimeIdentifier=tizen-x86`** — the path that resolves runtime pack assets,
and the one .NET MAUI takes via `EnableImplicitRuntimeIdentifiers`. The build succeeded with
0 errors.

It is therefore left as-is: making it well-formed would require either a non-standard wrapper
root or splitting the pack per .NET version, both of which carry more risk than the malformed
file does while nothing reads it. Check C6 parses it with a line-oriented regex rather than an
XML parser, matching how the file is actually produced and consumed. If a future SDK starts
reading it, C6 and this note are the places to revisit.
