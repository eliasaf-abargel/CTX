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

## Layout

The workspace adapts from compact to wide content widths. Layout decisions are
based on the actual content width, not the outer window frame.

- Long context, cluster, namespace, and user values truncate in the middle and
  expose the full value with help/tooltips.
- `ViewThatFits` is preferred for controls that can wrap or collapse naturally.
- Content stays leading-aligned inside capped max-width containers.
- Tables may reduce low-priority columns on compact widths, but horizontal
  scrolling stays inside the table panel when needed.
- Detail presentation is a single tabbed inspector sheet at every width.

## Typography and Spacing

- Section labels: 10-11pt, bold, secondary, uppercased.
- Body and table text: 12pt, primary.
- Titles: headline or 17-21pt bold depending on context.
- Standard content padding: 18-22pt.
- Card/panel padding: 13-14pt.
- Panel radius: 14pt.
- Banner radius: 12pt.
- Badge, button, and input radius: 8-9pt.

## Sidebar and Header

- Use native sidebar list behavior for workspace navigation.
- Keep future sections visible but disabled when they represent planned
  safety-reviewed workflows.
- Keep the identity footer pinned at the bottom.
- The header prioritizes context, cluster, provider, namespace scope, user, and
  environment.
- Refresh is a compact current-screen action.
- Namespace selection is a workspace scope control, not a global kubectl change.

## Status

- Use compact status indicators for persistent health state.
- Green means healthy, yellow means degraded/checking, red means error, and gray
  means unknown or not checked.
- Animations should only indicate active work. Settled states should stay still.
- Hover/click surfaces should explain status without turning the header into a
  dashboard.

## Tables

Resource screens use the shared `CTXResourceTable`.

- Tables show title, count, scope, load time, local filter, and selected row.
- Filtering is local-only and never starts kubectl.
- Namespace column appears only when the workspace scope can contain multiple
  namespaces.
- Numeric/status-shaped columns are right-aligned where appropriate.
- Copy affordances appear only for fields a user is likely to paste elsewhere.
- Secret and ConfigMap details stay metadata-oriented.

## Inspector

The resource inspector is one sheet with tabs:

- Overview
- YAML
- Logs, where supported

The header remains visible across tabs. Dismissing the inspector clears the
underlying row selection. Switching tabs updates the same presentation value
instead of presenting a second sheet.

## Buttons and Controls

- Use project-owned button styles for workspace text actions.
- Use icon-only action buttons for compact repeated actions such as export and
  diff, with tooltip/help and accessibility labels.
- Use menus for compact option sets such as log tail length.
- Use native save panels for local file export.
- Use system browser opening for external URLs; do not embed web content inside
  the app without a separate product and security decision.
- Avoid visible instructional text where a standard control communicates the
  action cleanly.

## States and Motion

- Loading states should be small and local to the affected panel.
- Error states show a short reason, Retry, optional details, and copy
  diagnostics.
- Empty and filtered-empty states should be concise.
- Preserve previous data while refreshing when possible.
- Motion should be subtle and short.

## Accessibility

- Tooltips/help are required for truncated values and icon-only controls.
- Buttons need stable hit targets and readable labels.
- Color can support status, but text or tooltip content must still carry the
  meaning.
