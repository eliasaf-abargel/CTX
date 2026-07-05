# Security and Safety

CTX is local-first. It must not store, transmit, print, or display cloud tokens,
kubeconfig credentials, bearer tokens, client cert data, private keys, or
Kubernetes secret values.

## Open-Source Privacy

- Committed tests, docs, screenshots, and previews must use generic fixture
  names.
- Do not commit real cluster names, namespaces, hostnames, node names, user
  identities, company identifiers, domains, or personal filesystem paths.
- Runtime data shown from the user's selected context is allowed, but it must
  not be copied into source fixtures.

## Kubernetes Workspace Rules

- Inspection only.
- No mutation commands without a future explicit safety design.
- No apply, patch, delete, drain, cordon, exec, shell, or YAML editing.
- Port Forward is allowed only through the dedicated Service workflow with
  explicit local ports, `127.0.0.1` binding, visible sessions, and Stop controls.
- Secret screens may show metadata only: namespace, name, type, key count, age.
- ConfigMap values are not displayed in the current workspace.
- Diagnostics must be sanitized and hidden behind explicit user action.
- Normal UI must never render raw stdout, raw stderr, tokens, or raw Kubernetes
  object JSON.

## Kubectl Execution

- Use `KubectlRunner`.
- Build commands as argument arrays.
- Never use shell interpolation.
- Always include explicit `--context`.
- Include `--kubeconfig` and `KUBECONFIG` when CTX discovered a specific config
  path.
- Use timeouts and cancellation-aware process termination.
- Never change global kubectl namespace or context.

## Diagnostics and Audit

- Diagnostics may include command kind, safe context name, safe kubeconfig path,
  exit code, duration, error category, and sanitized error summary.
- Redact tokens, cert data, key data, bearer values, and similar secrets.
- Future operational actions must create local audit events without sensitive
  payloads.

## Production and Admin Contexts

- Production/admin contexts must be visually obvious.
- Inspection mode remains active even for production/admin contexts.
- Future mutation gates must include environment warnings, RBAC preflight,
  preview/diff, explicit confirmation, and audit logging.
