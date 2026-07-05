# CTX Roadmap

CTX is a native macOS context switcher and Kubernetes inspection workspace. The
product remains local-first, generic, and open-source safe.

## Shipped

- AWS, GCP, Azure, and Kubernetes context discovery.
- Native menu bar and workspace app experience.
- Read-only Kubernetes Cluster Workspace.
- Overview diagnostics for API reachability, RBAC, namespaces, nodes, pods,
  workloads, services, ingress, events, configmaps metadata, and secrets
  metadata.
- Shared resource tables with local filtering and responsive columns.
- Resource inspector with Overview, safe YAML, and bounded Logs where supported.
- Standalone bounded Logs screen.
- Service-centered Map with selector-based Pods/Workloads and clickable Ingress
  hosts.
- JSON/CSV export for loaded resource data.
- Cached-vs-live Diff per resource kind.
- Service Port Forward with explicit local lifetime and Stop controls.
- Request deduplication, stale-while-revalidate cache behavior, cancellation,
  and debug-only performance logging.
- Sanitized diagnostics for auth plugin failures, local proxy refusal, RBAC
  denial, API errors, and timeouts.

## Next Stabilization

- Polish release packaging, signing, and notarization for public distribution.
- Keep diagnostics clear for Finder/Dock-launched sessions with reduced `PATH`.
- Add focused regression coverage for recent auth-plugin, tooltip, logs menu,
  export, and diff flows.
- Continue trimming stale docs, fixtures, and screenshots before each tag.

## Product Direction

- Command palette or quick navigation for resource screens and contexts.
- Better events timeline and resource correlation.
- Richer resource inspector sections, such as owner references and conditions.
- Richer topology layout once the selector-based map has enough runtime proof.
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
- AI-assisted troubleshooting that uses cluster data.

## Non-Goals

- No web UI stack.
- No CTX backend or telemetry.
- No mutation features in the current workspace.
- No secret value display.
