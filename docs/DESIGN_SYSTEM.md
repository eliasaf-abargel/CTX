# CTX Design System

CTX should feel like a native macOS infrastructure tool: calm, readable, fast,
and operationally clear.

## Principles

- SwiftUI-first and Apple-native controls first.
- Use AppKit only where SwiftUI cannot provide the required native behavior.
- Prefer system typography, color, material, spacing, and control sizing.
- Keep dark and light mode equally legible.
- Avoid web-app chrome, oversized marketing UI, and decorative noise.
- Use icon-only controls only when they have tooltips and accessibility labels.

## Structure and Layout

- The menu bar provides quick context access; the main window owns browsing and
  the Cluster Workspace.
- Settings use native tabs and grouped forms for providers, folders, appearance,
  updates, and application information.
- Workspace navigation uses a native sidebar and content sized from its available
  width rather than the outer window frame.
- `ViewThatFits` is preferred for controls that can wrap or collapse naturally.
- Content stays leading-aligned inside capped max-width containers.
- Long context, cluster, namespace, and identity values truncate in the middle
  and expose the full value through help text.

## Typography and Spacing

- Section labels: 10-11pt, bold, secondary, uppercased.
- Body and table text: 12pt, primary.
- Titles: headline or 17-21pt bold depending on context.
- Standard content padding: 18-22pt.
- Card/panel padding: 13-14pt.
- Panel radius: 14pt.
- Banner radius: 12pt.
- Badge, button, and input radius: 8-9pt.

## Workspace

- The header prioritizes context, cluster, provider, namespace, identity, and
  environment.
- Refresh is a compact action for the current section.
- Namespace selection changes workspace scope only.
- Loading and error states stay local to the affected panel and preserve previous
  data when possible.
- Errors show a short reason, Retry, optional details, and copyable sanitized
  diagnostics.

## Status

- Use compact status indicators for persistent health state.
- Green means healthy, yellow means degraded/checking, red means error, and gray
  means unknown or not checked.
- Animations should only indicate active work. Settled states should stay still.
- Hover/click surfaces should explain status without turning the header into a
  dashboard.

## Tables and Inspectors

Resource screens use the shared `CTXResourceTable`.

- Tables show title, count, scope, load time, local filter, and selected row.
- Filtering is local-only and never starts kubectl.
- Namespace column appears only when the workspace scope can contain multiple
  namespaces.
- Secret and ConfigMap details stay metadata-oriented.
- The resource inspector is one sheet with Overview, YAML, and supported Logs
  tabs; its header and selection remain consistent across tabs.

## Topology Map

- The Map uses a native SwiftUI canvas with system colors and controls.
- Search, health filters, zoom, fit, counts, and legend remain available without
  obscuring the graph.
- Node details adapt between an adjacent inspector and compact presentation.
- Hover, focus, selection, keyboard navigation, and accessibility descriptions
  convey the same relationships.

## Controls and Motion

- Use project-owned button styles for workspace actions.
- Use menus for compact option sets and native save panels for local exports.
- Open external URLs in the system browser.
- Empty and filtered-empty states remain concise.
- Motion should be subtle and short.

## Accessibility

- Tooltips and help are required for truncated values and icon-only controls.
- Buttons need stable hit targets and readable labels.
- Color can support status, but text or tooltip content must still carry the
  meaning.
