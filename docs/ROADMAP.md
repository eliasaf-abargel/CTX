# CTX Roadmap

CTX is a native macOS context switcher and Kubernetes inspection workspace. The
product remains local-first, generic, and open-source safe.

## Current Baseline

- AWS, GCP, Azure, and Kubernetes context discovery and verification.
- Native menu bar, main window, profile folders, settings, CLI guidance, and
  in-app sign-in.
- Read-only Kubernetes Overview, Issues, resources, GitOps, Helm, bounded Logs,
  exports, Diff, Service Port Forward, and interactive topology Map.
- Local caching, cancellation, sanitized diagnostics, and automatic updates.

## Near-Term Priorities

- Improve release packaging, signing, notarization, and update reliability.
- Expand regression coverage for authentication, discovery, workspace loading,
  topology interaction, export, diff, and port-forward lifecycle.
- Keep diagnostics clear for apps launched outside a login shell.
- Continue accessibility, responsive-layout, and large-cluster performance work.

## Product Direction

- Faster keyboard navigation across contexts and workspace sections.
- Better events timeline and resource correlation.
- Richer resource inspector sections for owner references and conditions.
- Additional topology relationships and layout refinement.
- More useful diff presentation for changed fields.
- Optional watch-backed live refresh with fallback to current polling.
- Multi-cluster organization and comparison without changing the read-only
  safety model.
- Deeper RBAC, quota, policy, and utilization inspection where the cluster
  exposes safe read-only data.

## Requires Dedicated Safety Design

These remain out of scope until CTX has explicit safety controls, audit,
confirmation, and privacy review:

- YAML editing.
- Apply, patch, delete, scale, drain, or cordon.
- Exec or shell.

## Non-Goals

- No web UI stack.
- No CTX backend or telemetry.
- No mutation features in the current workspace.
- No secret value display.
