# Cloud and Kubernetes Architecture

CTX discovers cloud and Kubernetes identity from local configuration files and
uses the user's installed command-line tools. There is no CTX-hosted backend,
no telemetry endpoint, and no credential store owned by CTX.

## Discovery

- AWS, GCP, Azure, and Kubernetes profiles are discovered from local config.
- Kubernetes contexts come from CTX's configured kubeconfig path, `KUBECONFIG`,
  or `~/.kube/config`.
- CTX never writes kubeconfig and never changes global `current-context`.
- Provider and environment labels are inferred from generic context, cluster,
  and server metadata. Detection falls back to `unknown` rather than relying on
  private names.

## Kubectl Boundary

All Kubernetes reads go through `KubectlRunner` and command builders in
`CTXCore`.

- Commands are built as argument arrays, never shell strings.
- Every Kubernetes command includes explicit `--context`.
- When a kubeconfig path was discovered, CTX passes both `--kubeconfig` and
  `KUBECONFIG`.
- CTX resolves common system and Homebrew paths so Finder-launched app sessions
  can still find `kubectl` and credential plugins such as `aws`.
- Timeouts and cancellation terminate the underlying process.

Allowed Kubernetes command families today:

- `kubectl version`
- `kubectl auth can-i`
- `kubectl get`
- `kubectl describe`
- `kubectl logs` with a bounded `--tail`

No mutation command families are used.

## Safety Boundaries

- Inspection only: no apply, patch, delete, scale, drain, cordon, exec, shell,
  port-forward, or YAML editing.
- Logs are bounded snapshots. CTX does not start indefinite `--follow` streams.
- Secrets are metadata-only: name, namespace, type, key count, and age.
- ConfigMaps are metadata-oriented until a redaction model exists.
- YAML inspection is disabled for resource kinds that can expose sensitive
  values.
- Diagnostics are sanitized before display and never render raw stdout in the
  normal UI.

## Resource Cache

`ResourceRefreshCoordinator` is the cache and request-dedup authority for
workspace resources.

- Cache keys include context identity, effective namespace, and resource kind.
- Fresh entries render immediately without starting another live read.
- Stale entries render immediately and revalidate in the background.
- Duplicate in-flight reads join one request instead of spawning extra
  `kubectl` processes.
- Failed live refreshes do not overwrite the last known good data.
- The UI projection mirrors coordinator results; it is not a second source of
  truth.

CTX may hydrate resource lists from a local SQLite cache to improve startup
speed. The disk cache stores only already-redacted resource list data. Logs,
YAML, command output, tokens, kubeconfig contents, and secret values are not
stored there.

## Refresh and Cancellation

- Opening a workspace loads identity, API health, RBAC, and namespaces.
- Resource screens lazy-load on first open.
- Manual refresh bypasses cache for the current screen.
- Namespace changes cancel namespace-scoped in-flight work.
- Active screens have priority over background prefetch.
- Each resource kind loads independently, so one slow or failed kind does not
  block the rest of the workspace.

Default timeouts are intentionally short enough to fail with a useful per-kind
diagnostic rather than leave the whole workspace spinning. Heavy all-namespace
reads get a longer timeout than ordinary reads.

## Diagnostics and Debug Logging

User-facing diagnostics include command kind, context, safe kubeconfig path,
exit code, duration, category, and sanitized stderr summary.

Debug builds also emit compact `[CTX perf]` lines for cache decisions, kubectl
duration, workspace lifecycle, namespace changes, YAML loads, and log fetches.
Those lines use hashed context identity and never include stdout, stderr,
tokens, kubeconfig contents, or secret values.

## Non-Goals

- No cluster mutations until a dedicated safety model exists.
- No credential storage owned by CTX.
- No CTX backend or telemetry.
- No Secret values, ever.
