# CI

`.github/workflows/build.yml` builds the whole Windows-only workspace on a
GitHub-hosted `windows-latest` runner and uploads the result as the
`kernel-script-windows-x64` artifact.

| output | how it is built |
| --- | --- |
| `ks-driver.sys` | `cargo build --release -p ks-driver --bin ks-driver --features wdk` with WDK `10.0.26100` + MSVC |
| `ks-gui.exe` | `cargo build --profile gui-release -p ks-gui` (unwind profile, so the GUI keeps `catch_unwind`) |
| `ks-test.exe` | `cargo build --release -p ks-test` |

Before shipping the image to `ks-sdk` the workflow asserts, as AGENTS.md
requires, that `ks-driver.sys` imports `ntoskrnl.exe` only (no `ntdll.dll`)
and is a Native-subsystem image.

## Required repository settings

The workspace resolves its mapper through the sibling path dependency
`dt-loader = { path = "../driver-toolkit/dt-loader" }`, whose sources live in
the private repository <https://github.com/lipeilin2006/driver-loader>. Cargo
resolves that path for **every** command, even `cargo build -p ks-driver`, so
CI has to materialise it before anything else.

| kind | name | value |
| --- | --- | --- |
| secret | `DT_LOADER_TOKEN` | fine-grained PAT with **Contents: Read** on the `driver-loader` repository |
| variable | `DT_LOADER_REPO` | optional, defaults to `lipeilin2006/driver-loader` |
| variable | `DT_LOADER_REF` | optional branch or tag, defaults to the repository default branch |

`DT_LOADER_TOKEN` is cloned with `AUTHORIZATION: basic` over
`x-access-token`, and the encoded header is masked in the log.

Without the secret the job still runs: it writes a placeholder `dt-loader`
crate so cargo can resolve the workspace, builds `ks-driver.sys`, and skips
the two binaries that link the mapper (`ks-sdk`, `ks-gui`, `ks-test`). This is
also what happens for pull requests from forks, which cannot read secrets.

## Triggers

* `push` to `main` and to `v*` tags (documentation-only changes are skipped)
* `pull_request`
* `workflow_dispatch` with
  * `gui_profile` - `gui-release` (default) or `release`
  * `publish_release` / `release_tag` - also upload the binaries as a draft
    GitHub release

## Toolchain on the runner

* Rust stable with `rustfmt`/`clippy` (`dtolnay/rust-toolchain`), `target/`
  restored by `Swatinem/rust-cache`
* MSVC through `ilammy/msvc-dev-cmd` (`cl.exe`, `link.exe`, `dumpbin.exe`)
* WDK `10.0.26100` through `.github/scripts/prepare-wdk.ps1`:
  1. an already installed kit (`C:\Program Files (x86)\Windows Kits\10`)
  2. `winget install Microsoft.WindowsWDK.10.0.26100`
  3. the public NuGet content packages `Microsoft.Windows.SDK.CPP`,
     `Microsoft.Windows.SDK.CPP.x64` and `Microsoft.Windows.WDK.x64`
     (the last one carries the `km` headers and kernel import libraries)

   The script exports `WDK_ROOT`, `WDK_LIB` and `WDK_VERSION`, which is exactly
   what `ks-driver/build.rs` requires; nothing is hard-coded into the workflow.

## Notes

* The driver is only ever built with `--release`: an unoptimised image
  overflows the worker thread's kernel stack on the first round trip.
* `ks-driver.sys` is not signed and the workflow does not sign it. Both
  executables embed the `requireAdministrator` manifest in release profiles.
* Windows Defender flags `ks-test.exe` in the KDU mode (`HackTool:Win64/...`);
  the artifact is for testing on a machine with an exclusion, not for
  redistribution.
* Local equivalent, from a checkout that already has
  `..\driver-toolkit\dt-loader`:

  ```powershell
  $env:KS_DRIVER_WDK = '1'   # with WDK_ROOT/WDK_LIB/WDK_VERSION set
  cargo build --release -p ks-driver --bin ks-driver --features wdk
  copy ks-driver.sys ks-sdk\assets\ks-driver.sys
  cargo build --profile gui-release -p ks-gui
  cargo build --release -p ks-test
  ```
