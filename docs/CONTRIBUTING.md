# Contributing

Thanks for helping CTX become a better native macOS tool.

## Build and Test

```bash
swift build
swift run CTXCoreTests
swift run CTXCheck
./script/build_and_run.sh verify
```

## Ground Rules

- Keep CTX generic and open-source safe.
- Do not commit real company, cluster, namespace, node, user, host, domain, or
  personal path data.
- Use generic fixtures such as `demo-namespace`, `production-namespace`,
  `demo-pod`, `api-service`, `node-a`, and `example-context`.
- Do not add mutation features without explicit design review.
- Do not copy GPL code.
- Keep the UI native: Swift, SwiftUI, Foundation, and AppKit only when needed.

## Code Style

- Keep SwiftUI views focused on presentation.
- Put process execution, parsing, discovery, and diagnostics in services.
- Do not call kubectl from views.
- Prefer clear names and small files. Split UI/workspace files as they approach
  300 lines.
- Add tests for command construction, mapping logic, safety, and regression
  cases.

## Kubernetes Safety

- All current workspace behavior is inspection-focused.
- Secret values must never be requested, decoded, displayed, logged, or placed
  in fixtures.
- Use explicit `--context` and safe argument arrays for kubectl.
- Never mutate global kubectl context or namespace.
