# Kubernetes Workspace

The Cluster Workspace is a native macOS inspection surface for Kubernetes
contexts discovered on the user's machine.

## Scope Model

Namespace selection is local to CTX and persisted per Kubernetes context. It
does not change global kubectl config.

- `All namespaces` uses `--all-namespaces`.
- A single namespace uses `--namespace <name>`.
- Cluster-scoped resources ignore namespace flags.

Cluster-scoped resources:

- Namespaces
- Nodes

Namespace-scoped resources:

- Workloads
- Pods
- Services
- Ingress
- ConfigMaps metadata
- Secrets metadata
- Events, where supported by the cluster

## Loading and Refresh

- Workspace open loads identity, API health, RBAC, and namespaces.
- Resource screens lazy-load on first open.
- Background prefetch warms common screens without blocking the active view.
- Header refresh reloads the current inspection screen.
- Retry buttons appear inside error panels.
- Cache and in-flight deduplication are owned by `ResourceRefreshCoordinator`
  in `CTXCore`; see [CLOUD.md](CLOUD.md).

Each resource kind has its own cancellable task. A timeout or RBAC error in one
kind does not block other kinds from loading.

## Resource Screens

Implemented screens use real read-only cluster data:

- Namespaces
- Nodes
- Workloads
- Pods
- Services
- Ingress
- ConfigMaps metadata
- Secrets metadata
- Events
- Map
- Logs
- Exports
- Diff
- Port Forward

Resource tables share one table implementation and support local filtering on
loaded rows. Filtering never runs kubectl.

## Inspector

Selecting a resource opens a single tabbed inspector sheet. The inspector owns
the detail experience at every window width, which keeps selection and tab state
consistent.

Tabs:

- Overview: curated fields, status, scope, and copyable references.
- YAML: lazy inspection YAML where safe.
- Logs: available for Pods, Services, and Workloads through the same bounded
  log reader used by the standalone Logs screen.

Unsupported tabs show a clear disabled reason rather than an empty or broken
view.

## YAML

YAML is inspection-only. There is no edit, apply, patch, or save-to-cluster
action.

Supported today:

- Namespace
- Node
- Pod
- Service
- Ingress
- Event

Disabled today:

- Secret, because it can contain encoded secret data.
- ConfigMap, because it can contain configuration values.
- Workload, until template redaction rules exist for env vars, volumes, and
  secret references.

## Logs

Logs use `KubernetesLogsReader` and always run bounded `kubectl logs --tail`
requests.

- The standalone Logs screen lets the user pick a pod from loaded pod data.
- A Pod inspector auto-selects that pod.
- Service and Workload inspectors discover related pods from selectors and then
  use the same log flow.
- Container selection appears only for multi-container pods.
- Tail length is chosen from a compact menu.
- Reload re-runs the same bounded read.

No logs path uses `exec`, shell, or an unbounded follow stream.

## Map

Map shows Service-centered relationships from loaded cluster data:

- Service to Pods through `spec.selector`.
- Service to Workloads by matching Pods that each Workload selector owns.
- Ingress hosts to Services through ingress backend service names.

Host buttons open the routed HTTP/HTTPS URL with the system browser. CTX does
not embed a web view in the app.

## Exports

Exports write already-loaded resource rows to JSON or CSV through the native
save panel. Exporting does not run a new kubectl command and does not send data
anywhere.

Only resource kinds with successfully loaded data appear as export candidates.

## Diff

Diff compares the cached list for a resource kind against one fresh
`bypassCache` read. Rows are matched by stable row id and summarized as added,
removed, or changed.

Diff uses the same read path as the resource screens; there is no separate
command surface.

## Port Forward

Port Forward starts an explicit local tunnel to a selected Service. It is
limited to `127.0.0.1`, requires local and remote ports, and always shows active
sessions with a Stop action.

The command uses the same kubectl boundary as the rest of the workspace:
explicit `--context`, preserved kubeconfig path, safe argument arrays, sanitized
diagnostics, and no shell interpolation.

## Diagnostics

Diagnostics include command kind, context, safe kubeconfig path, exit code,
duration, category, and sanitized stderr summary. Raw stdout is not displayed in
normal UI.

Common categories include:

- Missing or failing credential plugin.
- Local proxy or tunnel refusal.
- RBAC denial.
- Timeout.
- Kubernetes API unavailable.

## Boundaries

YAML editing, exec/shell, and cluster mutations remain future surfaces. They
require safety design, audit, confirmation, and privacy review before
implementation.
