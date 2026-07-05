# Kubernetes Workspace

The Cluster Workspace is a native Kubernetes inspection surface.

## Scope Model

The selected namespace is workspace-local and persisted per Kubernetes context.
It never mutates global kubectl config.

- `All namespaces` uses `--all-namespaces`.
- `default` uses `--namespace default`.
- A specific namespace uses `--namespace <name>`.
- Cluster-scoped resources ignore namespace flags.

Cluster-scoped resources:

- Namespaces
- Nodes

Namespace-scoped resources:

- Workloads
- Pods
- Services
- Ingress
- ConfigMaps
- Secrets metadata
- Events where supported by kubectl

## Loading, Cache, and Refresh

- Workspace open loads identity, API health, RBAC, and namespaces.
- Resource screens lazy-load on first open.
- The header refresh button refreshes the current inspection screen only.
- Retry buttons appear only inside error panels.
- Cache keys include context identity, resource kind, and effective namespace,
  owned by `ResourceRefreshCoordinator` (see `CLOUD.md`).
- Timeouts: `kubectl version`/verify 12s; ordinary lists, Nodes, Events, YAML,
  and Logs 12s (a soft "still loading" message appears after 3s, since a real auth-plugin round trip can outlast a plain list call); heavy all-namespace Pods/Events reads 20s. Kept short on
  purpose — a resource kind failing fast with a clear per-kind error and a
  working Retry beats the whole screen sitting on a spinner, since each kind
  is already an independent cancellable task and never blocks the others.
- Full caching/invalidation model, task-cancellation rules, and the future
  watch-API path live in `CLOUD.md` — this doc stays focused on the
  workspace's resource/namespace scope model.

## Resource Model: Specialized Today, Not Yet Generic

`KubernetesResourceKind` is a closed, `CaseIterable` enum (one case per
supported kind), each wired individually into columns, kubectl resource
name, and detail-section rendering (`KubernetesResourceModels.swift`,
`KubernetesResourceReader.swift`). Rows themselves (`cells: [String:
String]`) are already shape-agnostic, but adding a new kind — including a
future CRD — still means adding an enum case and touching ~5 switch
statements.

This is intentional for now: every supported kind has real, curated
detail-section fields, and a premature "generic apiVersion/kind/labels/
annotations" model would either duplicate that curation or produce a flatter,
less useful detail view. If/when CRD support becomes a real ask, the fix is
additive — a `.generic(gvk: GroupVersionKind)` case that falls back to
name/namespace/age/labels/annotations/status only, without disturbing the
specialized cases already curated above. No speculative generic layer is
being introduced ahead of that need.

## Resource Screens

Implemented screens load real cluster inspection data:

- Namespaces
- Nodes
- Workloads
- Pods
- Services
- Ingress
- ConfigMaps metadata
- Secrets metadata
- Events

Each screen supports local filtering on loaded rows. Filtering never runs
kubectl and displays `x of y items` when active.

## Selection and Detail: the Resource Inspector

Selecting a resource row opens `CTXResourceInspector` — one tabbed sheet, at
every window width, so it never clips and never requires scrolling down to
see it. Tabs:

- **Overview** (always) — kind, name, namespace when relevant, age, status,
  curated per-kind fields, and a copy-reference row.
- **YAML** (always present; disabled with a reason when unsupported — see
  below) — the resource's YAML for inspection.
- **Logs** (Pods, Services, Workloads) — a Pod's log tail directly;
  for Services/Workloads, a generic related-Pods picker first (see below).

The header (resource icon, title, subtitle, status) stays visible above the
tab bar regardless of which tab is active. Closing the inspector (Done or
Escape) routes through `dismissPresentation()`, which always clears the
underlying row selection at the same time — the previously-selected row's
highlight doesn't linger after the sheet is gone. Selecting a new row or
changing namespace/resource-kind replace or clear `presentation` directly.

Switching tabs is a mutation of the *same* presentation value
(`presentation?.tab = newTab`), not a dismiss-and-present-a-different-sheet.
See `DESIGN_SYSTEM.md` § Layout Breakpoints and § Inspector Tabs for why this
replaced three earlier designs that each broke in a different way — the
last one specifically was YAML as a *second* sheet, where presenting it
forced the inspector sheet to auto-dismiss, tearing out the very selection
state YAML needed to load.

## Inspection YAML

The YAML tab loads lazily the first time it's shown for a given resource.

Supported today:

- Namespace
- Node
- Pod
- Service
- Ingress
- Event

Disabled, with a visible reason inside the tab (not a broken/empty view):

- Secret, because it can contain encoded secret data.
- ConfigMap, because it can contain configuration values.
- Workload, until template redaction rules are designed (env vars and
  volumes can reference secrets).

YAML is for inspection. There is no edit, apply, patch, or save-to-cluster action.

## Logs

Inspection pod log tailing (`KubernetesLogsReader`), reachable two ways that
share the exact same fetch path and the exact same visual components — no
duplicated logs implementation:

- The standalone **Logs** sidebar screen: pick any pod from a list (loaded
  from the same cached Pods list as the Pods screen, so opening it doesn't
  trigger a second `get pods` call). Exactly one pod auto-selects; more than
  one shows `CTXPodPicker` — never a guess.
- The inspector's **Logs tab**, for a Pod already selected — auto-selects
  that pod instead of asking you to pick one.
- The inspector's **Logs tab** for a **Service** or **Workload** — discovers
  related Pods generically via `KubernetesRelatedPods` (`CTXCore`): a
  Service's `spec.selector`, or a Deployment/StatefulSet/DaemonSet's
  `spec.selector.matchLabels`, matched against each already-loaded Pod's own
  labels — the same mechanism `kubectl get pods -l <selector>` uses, no app
  name or label convention assumed. No selector → "Service has no selector" /
  "No selector found"; selector but no matching Pods → "No related Pods
  found"; otherwise a sorted picker, then the exact same logs flow as picking
  a Pod directly. A "Related Pods" back button returns to the picker without
  leaving the inspector.

Shared components (`CTXLogsComponents.swift`):

- `CTXPodPicker` — a popover of pod rows (name, workload/app label if known,
  status, ready, restarts, age), sorted Running/Ready first, then
  Warning/CrashLoop/Error, then Pending, then Completed/Terminated
  (`PodLogSelection` in `CTXCore`, unit tested).
- `CTXLogsControls` — pod picker, container picker (only shown when there's
  more than one), tail-length picker (100/500/1000), Reload, Copy.
- `CTXLogsViewer` — monospaced, independently vertical/horizontal scrolling,
  a line-wrap toggle, an ANSI-escape-stripping toggle (on by default),
  subtle dimming of each line's leading timestamp (display only — Copy
  always copies the untouched raw text), a line count, and auto-scroll to
  the newest line whenever the text changes.
- `CTXLogsIssuePanel` — the shared "fetch failed" state (Retry, Show/Hide
  details, Copy diagnostics).

Either way: the reader looks up the pod's container names via a single
`get pod -o jsonpath`, and a container picker appears only if there's more
than one. Fetching logs always uses a bounded `--tail` — never an unbounded
or indefinitely-following stream, so there's no long-running local process to
manage or clean up. Reload re-runs the same bounded tail; there is no
`exec`, no shell, no write path. The fetch task is cancelled on pod/
container/tail/namespace change, and when the inspector closes.

## Exports

Exports writes the rows already loaded for a resource screen to a local file
(JSON or CSV) via the native `NSSavePanel` — no network call, no new kubectl
command, just serializing data CTX already fetched. Only screens with
successfully loaded data appear as export candidates.

## Diff

Diff (`ClusterDiffView` / `ResourceDiffResult`) compares the currently cached
resource list for a kind against one fresh `bypassCache: true` re-fetch,
matching rows by their existing `id` to report added / removed / changed
counts and names. It reuses the same `KubernetesResourceReader.list` path as
every other read (no separate command surface), and the live re-fetch also
refreshes that kind's cache entry as a side effect — consistent with a normal
refresh.

## Diagnostics

Diagnostics include command kind, context, safe kubeconfig path, exit code,
duration, category, and sanitized stderr summary. Raw stdout is not shown in
normal UI. Every kubectl call additionally emits one `DEBUG`-only timing line
(see `CLOUD.md` § Instrumentation) — kind, scope, cache vs. live, duration,
outcome; never command output, tokens, or kubeconfig contents.

## Roadmap Boundaries

Port-forward, YAML editing, exec/shell, and mutations remain future surfaces.
They require safety design, audit, confirmation, and privacy review before
implementation — see `ROADMAP.md`.
