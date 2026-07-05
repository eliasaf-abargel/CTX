# CTX Agent Guide

CTX is a generic, open-source, native macOS cloud and Kubernetes context tool.
Keep it fast, local, safe, and Apple-native.

## Product Vision

- CTX should help any developer inspect and switch cloud/Kubernetes contexts.
- Do not hardcode private company, cluster, namespace, node, user, domain, or
  personal path data in source, tests, previews, docs, or fixtures.
- Runtime data from a user's machine or cluster may be displayed when the user
  opens that context, but committed examples must stay generic.

## Stack Rules

- Use Swift, SwiftUI, Foundation, and AppKit only where SwiftUI cannot do the
  job cleanly.
- Do not introduce React, Electron, WebView, Wails, Tauri, Node UI, Go UI, or
  any non-native UI stack.
- Do not copy GPL code.
- Preserve existing AWS, GCP, Azure, and Kubernetes behavior.

## Architecture Rules

- SwiftUI views own presentation only.
- ViewModels own window state, selection, cancellation, and async loading.
- Services own Kubernetes discovery, parsing, health checks, resource reads,
  diagnostics, and kubectl access.
- Kubectl execution must go through `KubectlRunner`.
- Do not put kubectl calls, JSON/YAML parsing, or kubeconfig parsing in SwiftUI
  views.
- Keep `ProfileStore` as compatibility glue; do not grow it for workspace
  logic.
- Prefer files below 300 lines for UI/workspace code. Split by responsibility
  before a view becomes a mixed-purpose file.

## Kubernetes Safety

- Cluster Workspace is inspection-focused until a future safety model exists.
- Do not add apply, patch, delete, drain, cordon, exec, shell, port-forward, or
  YAML editing.
- Do not display or log secret values.
- Always pass explicit `--context`.
- Preserve discovered kubeconfig paths with `--kubeconfig` and `KUBECONFIG`.
- Use safe argument arrays only. No shell interpolation.

## Phased Work

- Keep phases small and shippable.
- Prefer stabilizing existing inspection flows before adding new feature areas.
- Report changed files, tests, safety checks, file-size outliers, and deferred
  work.

## Verification

Run these before reporting completion:

```bash
swift build
swift run CTXCoreTests
swift run CTXCheck
./script/build_and_run.sh verify
```
