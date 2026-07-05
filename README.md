<p align="center">
  <img src="Resources/CTXIcon.svg" width="120" height="120" alt="CTX Logo" />
</p>

<h1 align="center">CTX</h1>

<p align="center">
  <strong>A native macOS context switcher and Kubernetes inspection workspace.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-blue?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/language-Swift%206-orange?style=flat-square" alt="Language" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License" />
</p>

CTX is a lightweight local app for developers who switch between cloud and
Kubernetes contexts. It discovers existing AWS, GCP, Azure, and kubeconfig
state on your Mac, keeps the UI native, and uses your installed command-line
tools instead of a hosted backend.

The Kubernetes Cluster Workspace is inspection-focused: it reads cluster state
through explicit `kubectl --context` commands, keeps namespace selection local
to CTX, and does not mutate the cluster.

## Features

- Native SwiftUI macOS app with menu bar and workspace windows.
- AWS, GCP, Azure, and Kubernetes context discovery.
- Kubernetes Overview with API, RBAC, namespaces, nodes, pods, workloads,
  services, ingress, configmaps metadata, secrets metadata, and events.
- Resource tables with local filtering, detail inspector, safe YAML inspection,
  bounded logs, JSON/CSV export, and cached-vs-live diff.
- Service topology map, clickable ingress hosts, and local Service Port Forward.
- Clear diagnostics for common local issues such as missing credential plugins,
  local proxy refusal, RBAC denial, and timeouts.
- Local-first behavior: no CTX backend, no telemetry, and no secret value
  display.

## Install

Download the latest signed release from the repository's Releases page and move
`CTX.app` to `/Applications`.

For a local development build:

```bash
./script/build_and_run.sh run
```

## Requirements

- macOS 14.0 or newer.
- Xcode 15 or newer, or a compatible Swift 6 toolchain for development.
- `kubectl` for Kubernetes inspection.
- Provider CLIs only for contexts that need them, for example `aws` for EKS
  exec credential plugins or `gcloud` for GKE auth.

When CTX is opened from Finder or the Dock, macOS may provide a smaller `PATH`
than an interactive terminal. CTX resolves common Homebrew and system paths, but
credential plugins still need to be installed on the machine.

## Development

Run the full local verification stack before shipping changes:

```bash
swift build
swift run CTXCoreTests
swift run CTXCheck
./script/build_and_run.sh verify
```

Useful build script modes:

```bash
./script/build_and_run.sh run
./script/build_and_run.sh logs
./script/build_and_run.sh verify
```

## Kubernetes Safety Model

Current Kubernetes behavior avoids cluster mutation. CTX does not run `apply`,
`patch`, `delete`, `scale`, `drain`, `cordon`, `exec`, shell, or YAML edit
operations. Port Forward is limited to explicit local Service tunnels with
visible Stop controls.

Secret resources are metadata-only. ConfigMap values and Secret values are not
displayed, logged, exported, or cached as raw values.

See [SECURITY.md](SECURITY.md), [CLOUD.md](CLOUD.md), and
[KUBERNETES_WORKSPACE.md](KUBERNETES_WORKSPACE.md) for the implementation
boundaries.

## Documentation

- [CLOUD.md](CLOUD.md): cloud and Kubernetes architecture.
- [KUBERNETES_WORKSPACE.md](KUBERNETES_WORKSPACE.md): workspace behavior.
- [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md): native macOS UI rules.
- [SECURITY.md](SECURITY.md): safety and privacy boundaries.
- [ROADMAP.md](ROADMAP.md): planned product direction.
- [CONTRIBUTING.md](CONTRIBUTING.md): contribution rules.
- [AGENTS.md](AGENTS.md): coding-agent instructions for this repository.

## License

CTX is released under the MIT License.
