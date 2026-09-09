<p align="center">
  <img src="Resources/CTXIcon.svg" width="112" height="112" alt="CTX logo" />
</p>

<h1 align="center">CTX</h1>

<p align="center">
  <strong>Native macOS cloud context switching and Kubernetes inspection.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-5.10%2B-orange?style=flat-square" alt="Swift 5.10+" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT license" />
</p>

CTX discovers AWS, GCP, Azure, and Kubernetes contexts from local configuration
and uses the command-line tools already installed on your Mac. It has no hosted
backend, account, or telemetry.

## Features

- Fast context access from a native menu bar app and main window.
- AWS, GCP, Azure, and Kubernetes profile discovery, verification, and switching.
- Profile folders plus provider, folder, appearance, and update settings.
- CLI discovery across common macOS install locations, with guided installation
  when a required tool is missing.
- Existing-session reuse and in-app sign-in when authentication is required.
- A read-only Kubernetes workspace with Overview, Issues, resource tables,
  bounded logs, GitOps, Helm, exports, diff, Service port forwarding, and an
  interactive topology Map.
- Automatic update checks with an in-app install action.

## Install

Download `CTX.app.zip` from [GitHub Releases](https://github.com/eliasaf-abargel/CTX/releases),
extract it, and move `CTX.app` to `/Applications`.

To install the latest release with the repository script:

```bash
./script/install.sh
```

To build and run from source:

```bash
./script/build_and_run.sh run
```

## Requirements

- macOS 14 or newer.
- Swift 5.10 or newer when building from source.
- The CLI for each provider you use: `aws`, `gcloud`, `az`, or `kubectl`.
- `helm` for full Helm release details; CTX can fall back to safe metadata.
- `sdm` or `tsh` only for clusters that use those access brokers.

CTX never installs tools without your action.

## Safety

Kubernetes inspection always uses an explicit context and preserves the
discovered kubeconfig path. CTX does not apply, patch, delete, scale, drain,
cordon, exec, open a shell, or edit YAML.

Secret and ConfigMap values are not displayed, logged, exported, or cached.
Port forwarding is limited to explicit Service tunnels bound to `127.0.0.1`,
with visible sessions and Stop controls.

## Development

```bash
swift build
swift run CTXCoreTests
swift run CTXCheck
./script/build_and_run.sh verify
```


## License

CTX is available under the [MIT License](LICENSE).
