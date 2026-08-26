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

The band string is derived generically from `DOTNET_VERSION`, so `11.0.100-rc.1.*` and the
eventual `11.0.100` GA need no further code change. This is asserted by
[`scripts/test-version-band.sh`](../scripts/test-version-band.sh).

## What changed in this repository

| File | Change |
|---|---|
| `build/Versions.props` | `MicrosoftDotNetBuildTasksFeedPackageVersion` = `11.0.0-beta.26426.103` when building an `11.0` band |
| `NuGet.config` | added the `dotnet11` package source |
| `src/Samsung.Tizen.Sdk/targets/Samsung.Tizen.Sdk.targets` | added the `net11.0` `KnownRuntimePack` |
| `src/Samsung.NETCore.App.Runtime/data/RuntimeList.xml` | added the `.NET Runtime 11` `FileList` row |
| `src/Samsung.Tizen.Templates/.../template.json` | added the `net11.0` framework choice (default stays `net10.0`) |
| `scripts/test-matrix.sh` | added `net11.0-tizen11.0` / `net11.0-tizen10.0` rows, skipped when no 11.x SDK is present |
| `scripts/validate-workload-metadata.py` | new checks C5/C6 tying template + matrix TFMs to `KnownRuntimePack` and `RuntimeList.xml` |
| `scripts/test-version-band.sh` | new — asserts SDK-version → feature-band mapping for both installers |
| `.github/workflows/build-matrix.yml` | added a non-blocking .NET 11 preview matrix leg |

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
