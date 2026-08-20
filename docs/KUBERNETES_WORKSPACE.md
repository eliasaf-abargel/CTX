# Kubernetes Workspace

The Cluster Workspace is CTX's native, read-only inspection surface for a
selected Kubernetes context.

## Scope and Loading

Namespace selection is stored per context inside CTX and never changes the
global kubectl namespace or current context.

- `All namespaces` uses `--all-namespaces`.
- A selected namespace uses `--namespace <name>`.
- Namespaces and Nodes remain cluster-scoped.

Opening a workspace loads identity, API health, RBAC, and namespaces. Other
sections load on demand, use cancellable requests, and can refresh independently.
`ResourceRefreshCoordinator` owns memory caching, stale-while-revalidate
behavior, and in-flight request deduplication.

## Workspace Sections

- **Overview** — identity, access, health, resource totals, and live utilization.
- **Issues** — unhealthy Pods and Nodes with local status filtering.
- **Resources** — Namespaces, Nodes, Workloads, Pods, CronJobs, Services,
  Ingress, ConfigMaps metadata, Secrets metadata, Events, HPA, and persistent
  volume claims.
- **GitOps** — Argo CD Applications plus Flux Kustomizations and HelmReleases,
  when installed.
- **Helm** — releases from the Helm CLI, with a metadata-only storage fallback
  when Helm is unavailable.
- **Map** — an interactive topology graph with search, health filtering, zoom,
  keyboard navigation, responsive detail inspection, and related-resource
  selection.
- **Utilities** — bounded Logs, JSON/CSV Exports, cached-versus-live Diff, and
  Service Port Forward.

Resource tables share one implementation and filter already-loaded rows locally;
typing in a filter does not run kubectl.

## Resource Inspector

Selecting a resource opens one tabbed inspector:

- **Overview** shows curated status, scope, and references.
- **YAML** loads inspection-only YAML for safe resource kinds.
- **Logs** is available for Pods, Services, and Workloads.

YAML is disabled for Secrets, ConfigMaps, and workload templates that may expose
sensitive values. Unsupported tabs explain why they are unavailable.

## Logs, Export, and Diff

Logs are bounded `kubectl logs --tail` snapshots. CTX does not use `exec`, a
shell, or an indefinite follow stream.

Exports write already-loaded, redacted rows to JSON or CSV through the native
save panel. Diff compares a cached resource list with one fresh read and reports
added, removed, and changed rows.

## Port Forward

Port Forward is limited to Services. Each session requires explicit local and
remote ports, binds to `127.0.0.1`, remains visible while active, and has a Stop
action.

## Command and Data Boundaries

All Kubernetes commands use `KubectlRunner`, explicit `--context`, the discovered
kubeconfig path, argument arrays, timeouts, cancellation, and sanitized
diagnostics. CTX does not apply, patch, delete, scale, drain, cordon, exec, open
a shell, or edit YAML. Secret and ConfigMap values are never displayed.
