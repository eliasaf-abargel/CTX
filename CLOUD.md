# Cloud & Kubernetes Architecture

CTX discovers cloud/Kubernetes identity from local config files and talks to
clusters exclusively through the user's own `kubectl` — there is no CTX
backend, no telemetry endpoint, and no credential storage of its own.

## Cluster Connection

- Contexts come from the user's existing kubeconfig(s) via
  `KubeConfigDiscoveryService` / `KubeConfigParser`. CTX never writes to
  kubeconfig and never changes the user's current-context.
- Provider (`eks` / `gke` / `aks` / `local` / `unknown`) and environment
  (`production` / `staging` / `development` / `admin` / `unknown`) are
  inferred generically from context/cluster name and server URL tokens
  (`KubernetesProviderDetector`, `EnvironmentDetector` — pattern match on
  words like "prod", "stg", "eks", "gke", never on a hardcoded org, account,
  or cluster name). Detection carries a confidence score and falls back to
  `unknown` rather than guessing wrong.
- Every kubectl invocation is built as an explicit, inspection-safe argument list
  (`KubectlCommandBuilding`) scoped to one context and one optional
  `--kubeconfig` path — a workspace never touches another context's config.

## Security Boundaries

- **Inspection, always.** No apply/patch/delete/scale/exec/port-forward
  anywhere in the resource reader, health service, YAML viewer, or logs
  reader. This is enforced by only ever building `kubectl get / describe /
  logs / auth can-i / version` commands.
- **Logs** (`KubernetesLogsReader`) always fetch a bounded `--tail=200` — never
  `--follow` or an unbounded stream. There's no long-running local process to
  track or kill because there's no long-running process at all: each load is
  one `kubectl logs` invocation that returns and exits, same as every other
  read in the app.
- **Every kubectl invocation goes through `KubectlRunner`/`KubectlCommandBuilding`.**
  Arguments are always passed as an array to `Process`, never through a shell
  (`/bin/sh -c`) — there is no shell interpolation anywhere in the Kubernetes
  read path, so there's no command-injection surface from a resource/pod/
  namespace name containing shell metacharacters.
- **Secrets:** only `kubectl get secrets --no-headers` (name/type/key count)
  is ever run. Secret *values* are never requested, never parsed, never
  cached, and the YAML viewer refuses Secret kind entirely
  (`KubernetesResourceKind.supportsInspectionYAML == false` for
  `.secretMetadata`).
- **ConfigMaps:** listed as metadata (name, key count, age) only; no raw
  `data` values are fetched or rendered until a redaction model exists.
- **Diagnostics** are sanitized before display (`KubernetesDiagnosticClassifier.sanitize`)
  so stderr/paths shown in the UI can't leak local file paths or tokens
  verbatim.

## Caching Model

Two layers, one authority. `ResourceRefreshCoordinator` (`CTXCore`, an
`actor`) is the single cache/dedup decision-maker, keyed by `context.id` +
effective namespace + resource kind, for both layers:

- **L1 — in-memory** (primary, always present). Decides, per fetch:
  - **Hit** (entry younger than the stale threshold, 30s) — returns the
    cached list with no live call.
  - **Stale** or **miss** — performs a live call, joining an already
    in-flight identical request instead of starting a second one (so a
    screen visited from two places at once, e.g. the sidebar and a
    background prefetch, never causes a duplicate `kubectl` process).
  - A **failed** live call never overwrites a good cached entry — the caller
    gets the failure to display, but the coordinator keeps serving the last
    known-good list to the next caller.
- **L2 — `SQLiteResourceCache`** (`CTXCore`, an `actor` around the system
  `libsqlite3` — no package dependency), opt-in per coordinator instance
  (`nil` in every test; the real app wires a real one in
  `ClusterWorkspaceViewModel.init`). On an L1 miss, the coordinator hydrates
  from disk before deciding whether a live call is needed. Disk-hydrated data
  is, by definition, from a previous app run — always older than the stale
  threshold — so it always reads as **stale**: it renders immediately, and
  the normal stale-while-revalidate path kicks off a live refresh right
  behind it. Every successful live fetch writes through to disk
  (fire-and-forget — the caller never waits on the disk write). Stores only
  `KubernetesResourceList` JSON, keyed the same way as L1; nothing else is
  ever passed to its API. Because Secrets/ConfigMaps are already
  metadata-only by the time they become a `KubernetesResourceList` (see
  Security Boundaries above), persisting one is exactly as safe as caching it
  in memory already was — YAML and Logs results are different types and are
  never given to this cache at all.
- **Production-hardened on open**: WAL + a 2s busy timeout (multiple workspace
  windows each hold their own connection to the same file). An integrity
  check (`PRAGMA quick_check`) runs before the schema is touched — a
  corrupted file (a prior crash mid-write, or manual damage) is deleted and
  recreated fresh exactly once rather than leaving the cache silently and
  permanently non-functional; this is a disposable cache, never a source of
  truth, so discarding a corrupted copy is always safe. Entries older than
  30 days are pruned on open — a startup seed this old has long since been
  superseded by live refreshes, so keeping it forever would only cost disk
  space, especially for dynamic clusters where namespaces come and go often.

`KubernetesResourceReader` itself has no cache of its own — an earlier
reader-level `KubernetesResourceCache` actor existed alongside the view
layer's own dict, but the view layer's own staleness guard meant the reader's
cache could never actually serve a hit in practice. It was removed rather
than left in place as a second, silently-bypassed cache.

`ClusterWorkspaceViewModel.resourceLists` is a thin **UI-binding projection**,
not a third cache: it always mirrors whatever the coordinator last returned
for a key, plus `refreshErrors: [String: KubernetesCommandDiagnostic]` for the
one case that needs to diverge from the coordinator's view — a background
refresh that failed while good data is still cached. In that case the good
data stays in `resourceLists` (never blanked), and `refreshErrors` carries the
failure so the UI can show a small "Refresh failed" banner over the existing
table instead of replacing it with an error panel.

Closing a cluster window deallocates the `ViewModel` and its coordinator, so
the **in-memory** cache never crosses windows or sessions. Switching
Kubernetes context opens a distinct `ClusterWorkspaceViewModel` (and
coordinator) keyed by context id, so stale data from one cluster can't leak
into another by construction (see `ClusterWorkspaceScene` in
`ClusterWorkspaceView.swift`). The **disk** cache does persist across app
launches by design (that's its whole purpose); `SQLiteResourceCache.clearContext(_:)`
removes every entry for one context, so removing a Kubernetes context from
CTX also removes its stale disk cache rather than leaving it to resurface
under a context CTX no longer knows about.

## Refresh Model

- Manual refresh / Retry: `refreshCurrentScreen()` re-runs the current
  section's load with `bypassCache: true`, which always forces a live call
  through the coordinator even over a fresh cache hit.
- **Automatic stale-while-revalidate** (`ClusterWorkspaceViewModel.staleThreshold`,
  30s, mirrored into the coordinator): switching to a section — or back to
  Overview — with cached data older than 30 seconds shows that cached data
  immediately and unchanged, while a real background reload quietly replaces
  it once it lands. Below 30 seconds, switching back to an already-loaded
  section does nothing extra — instant, no network call.
- Every load is a cancellable `Task`, tracked per resource kind
  (`resourceTasks: [KubernetesResourceKind: Task<Void, Never>]`), plus one
  each for the overview refresh and the YAML load. Switching namespace
  cancels in-flight tasks for every namespace-scoped kind (both the
  view-model-level `Task` and, via `ResourceRefreshCoordinator.cancel(...)`,
  the in-flight fetch itself — including terminating the underlying kubectl
  process through `KubectlRunner`'s cancellation handler), so a slow response
  for the namespace just left can never land as if it were current. Nodes and
  Namespaces are cluster-scoped and are deliberately **not** reloaded on a
  namespace switch.
- Workspace open and namespace switch schedule every other resource kind as a
  background prefetch (`ClusterWorkspaceViewModel.prefetchWorkspaceResources()`,
  `handleNamespaceChange`'s namespace-scoped loop) so navigating to a screen
  right after either event is usually already warm. `loadResource` skips
  re-issuing a fetch for a kind that's already in flight instead of
  cancelling and restarting it, so a prefetch racing against the user
  clicking that same screen never produces two live calls.
- **Adaptive priority** (`FetchPriority`, `KubectlConcurrencyGate` in
  `CTXCore`): the screen the user is actually looking at always fetches with
  `.active` priority and never waits on anything. Prefetch always fetches
  with `.background` priority and is capped to a small number of concurrent
  kubectl processes (`KubectlConcurrencyGate`, default 3) — so a wave of
  eight prefetch calls at workspace-open can't flood the same auth plugin
  the active screen is also waiting on, and can never delay it. If an
  `.active` request arrives for a key that already has a `.background` fetch
  in flight, the coordinator cancels that gated background attempt and
  starts a fresh, ungated one rather than joining it — an `.active` caller
  must never inherit a wait behind the concurrency gate just because
  prefetch happened to get there first (this was a real bug: it made a
  Nodes screen open take far longer than an uncontended manual
  `kubectl get nodes`, even though the subprocess itself, once actually
  running, completed in a few seconds).
- `KubernetesResourceList.loadedAt` is shown in the list subtitle
  ("`N items · scope · h:mm`") so staleness is always visible, not hidden
  behind a spinner.
- The cluster health check (`ClusterOverviewView` / health dot menu) runs its
  RBAC probes concurrently via `withTaskGroup` rather than sequentially,
  bounded by the slowest single call instead of the sum of all of them.
- Per-operation timeouts: `kubectl version`/context verify 5s; ordinary
  resource lists, Nodes, Events, YAML, and Logs 12s (a soft "still loading" message appears after 3s without cancelling anything); heavy all-namespace
  Pods/Events reads 20s. Every resource kind is its own cancellable `Task`,
  so one kind timing out never blocks the others.

## Instrumentation

Every kubectl invocation, cache decision, and workspace-lifecycle step (app
connect, verify kubectl, cluster health, workspace open, namespace switch,
screen open, retry, YAML load, logs pod list, logs fetch) logs one `print`
line in `DEBUG` builds only, via `CTXPerfLog`:

```
[CTX perf] step=screen_open context=d6c3c79e namespace=production kind=pods cache=hit durationMs=0 outcome=success
[CTX perf] step=kubectl_command context=d6c3c79e namespace=production kind=pods cache=none durationMs=812 outcome=success
[CTX perf] step=namespace_switch context=d6c3c79e namespace=staging kind=workspace cache=none durationMs=1 outcome=success
```

Fields: `step`, `context` (an 8-hex-character one-way hash of the context
identity — never the real context/cluster name), `namespace` (`cluster` for
cluster-scoped kinds), `kind`, `cache` (`hit`/`stale`/`miss`/`none`),
`durationMs`, and `outcome` (`success`/`timeout`/`error`/`cancelled`). Never
logs stdout, stderr, tokens, secret values, or kubeconfig contents. This is a
debugging aid for spotting duplicate reloads, slow calls, or unexpected cache
misses during development, not a user-facing log viewer.

## `ResourceRefreshCoordinator`

Lives in `CTXCore` (not the `CTX` app target) specifically so it's unit
testable — view models in the app target can't be imported by
`CTXCoreTests`, but a plain `CTXCore` actor can. It owns:

- `fetch(contextID:context:namespace:kind:bypassCache:)` — the cache
  hit/stale/miss decision, live-call dedup, and known-good-data preservation
  on failure described above.
- `cancel(contextID:namespace:kind:)` — cancels in-flight fetches, scoped as
  narrowly as the caller needs (a whole context, or just one namespace).
- `invalidate(contextID:namespace:kind:)` — drops cached entries.

See `Sources/CTXCoreTests/main.swift` for its test coverage (cache/namespace
isolation, concurrent-fetch dedup, stale-data preservation on a failed
refresh, cancellation dropping in-flight work, Retry bypassing a fresh hit).

## Future: Watch API

No watch/informer support exists yet. The intended path, once introduced:
extend `ResourceRefreshCoordinator` to own one `kubectl get --watch -o json`
(or client-go informer, if CTX ever links a Kubernetes client library) stream
per active resource kind, applying add/update/delete events onto the same
`KubernetesResourceList` shape already in `resourceLists`, so the table/detail
views need no changes. Falls back to the current poll-on-demand model
automatically if the watch stream errors or the server doesn't support it
(e.g. some managed RBAC setups deny `watch` even when `get`/`list`
are allowed).
- Still bound by the same safety rule: watch is a read verb, not a
  mutation — this does not change the no-mutation boundary anywhere else in
  the app.

## Non-Goals

- No cluster mutations (no apply/patch/delete/scale/exec/port-forward).
- No credential storage, no CTX-hosted backend, no telemetry.
- No Secret values, ever.
