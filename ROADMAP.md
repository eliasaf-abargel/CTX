# CTX Roadmap

CTX is moving toward a polished, Apple-native context and Kubernetes inspection
workspace. The product remains local-first, generic, and open-source friendly.

## Shipped

- Stable cloud and Kubernetes context discovery (AWS, GCP, Azure, kubeconfig).
- Inspection Cluster Workspace: LED-style health indicator, namespace scoping,
  resource tables (`CTXResourceTable`, shared across all 9 kinds), row
  selection.
- **`CTXResourceInspector`**: one tabbed sheet (Overview / YAML / Logs-for-Pods)
  at every window width, driven by a single struct —
  `ClusterWorkspacePresentation { selection, tab }` — instead of independent
  presentation flags per feature. Switching tabs mutates that one value in
  place; there is no second sheet to fight over state (see `DESIGN_SYSTEM.md`
  § Inspector Tabs for what this replaced and why).
- Inspection YAML inside the inspector's YAML tab for supported kinds, with a
  visible disabled reason (not a broken tab) for unsupported ones.
- Inspection Logs inside the inspector's Logs tab (Pods only) and the
  standalone Logs sidebar screen, both sharing one fetch implementation:
  container picker, tail-length picker (100/500/1000), reload, copy — no
  exec, no unbounded/following stream.
- Exports: loaded resource data to local JSON/CSV via the native save panel.
- Diff: cached-vs-live comparison per resource kind (added/removed/changed).
- In-memory, per-window caching via `ResourceRefreshCoordinator` (see
  `CLOUD.md`) — the single cache/dedup authority, unit tested in `CTXCore` —
  with cancellable per-resource-kind async loads, structured `[CTX perf]`
  timing instrumentation, and real stale-while-revalidate (30s threshold —
  cached data shows immediately, a background reload replaces it silently
  once it's actually stale, including Overview's health/RBAC check, which
  previously only ever ran once per window). A failed background refresh
  never blanks a screen that already had good data — it stays visible with a
  small "Refresh failed" indicator instead.
- Native macOS layout: `ViewThatFits`-based responsive breakpoints, subtle
  transitions, no custom search chrome where a native `List` suffices.

## Phase 3 — Resource Inspector and Safe YAML

The tabbed inspector itself has shipped (see "Shipped" above). What remains:

- Broaden inspection YAML to more kinds once redaction rules exist for
  workload templates (env vars, volume mounts that may reference secrets).
- Richer Overview-tab sections (owner references, condition history) without
  ever pulling values that require Secret access.
- A Logs tab experience for Workloads (list/pick related pods) — deliberately
  not built yet: it needs real pod↔workload correlation via label selectors,
  which is new logic, not a polish pass on what already exists.

## Phase 4 — Live Refresh and Watch API

`ResourceRefreshCoordinator` itself has shipped (see "Shipped" above) as the
cache/dedup/stale-while-revalidate authority. What remains: extend it (see
`CLOUD.md`) to move from polling (manual or stale-triggered) to a
`kubectl get --watch` / informer-backed stream per active resource kind, with
automatic fallback to polling. This phase is specifically about push-based
updates instead of polling on a timer/threshold.

## Phase 5 — Events Timeline

- Events as a real timeline view (not just a table), correlated to the
  selected resource where possible. (Inspection log tailing itself has
  shipped — see "Shipped" above.)

## Phase 6 — Multi-cluster Workspace

- Multiple open Cluster Workspace windows/tabs with independent caches
  (already possible per-window today; formalize switching/organizing them).
- Side-by-side or quick-switch comparison of the same resource kind across
  contexts, still gated by the safety model.

## Phase 7 — Policy / RBAC / Cost / Enterprise Insights

- Deeper RBAC visualization beyond the current allow/deny summary.
- Inspection policy and quota insight (ResourceQuota, LimitRange, PDBs).
- Cost/utilization overlays where a cluster exposes inspectable data
  (e.g. metrics-server, existing cost-exporter CRDs) — CTX never becomes a
  billing system of record.

## Later / Requires Dedicated Safety Design

- GitOps awareness for Argo CD and Flux without taking ownership of writes.
- Safe YAML editing only after diff, audit, RBAC preflight, and confirmation.
- Port-forward manager with explicit lifetime, local port visibility, and audit.
- Exec/shell only with strict safety controls, session warnings, and audit.
- AI-assisted troubleshooting with privacy boundaries and local diagnostics.

## Non-Goals Until Safety Exists

- No cluster mutations.
- No global kubectl context or namespace mutation.
- No secret value display.
- No web UI stack.
