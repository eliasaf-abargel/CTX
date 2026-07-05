# CTX Design System

CTX should feel like a premium native macOS infrastructure tool: calm, readable,
fast, and operationally clear.

## Direction

- SwiftUI-first, native macOS controls first.
- Refined Liquid Glass-inspired surfaces, but readability wins over blur.
- Use system-adaptive color, typography, material, spacing, and control sizing.
- Dark and light mode must both be legible.
- Avoid noisy dashboards, web-app chrome, and oversized marketing UI.

## Layout Breakpoints

Breakpoints are measured from the actual content width (via `GeometryReader`
+ `PreferenceKey`), not the window frame, so they react correctly even inside
a split view. Defined in `ClusterWorkspaceLayoutMode`:

| Mode | Width range | Title | Subtitle | Chips | Table columns | Inspector | Action buttons | Header |
|---|---|---|---|---|---|---|---|---|
| Compact | `< 860pt` | 21pt bold, truncates middle | 13pt monospaced, truncates middle | Stack vertically (`ViewThatFits`) when they don't fit one row | Minimal set per kind (e.g. Pods: Namespace/Name/Status/Ready) | Centered sheet (see below) | Wrap to a second row via `ViewThatFits`, never overflow | Stacked: icon+title row, then status row below |
| Regular | `860–1179pt` | Same as Compact | Same as Compact | One row if it fits, else stacks | Primary set per kind (adds e.g. Version/Class/Address) | Same centered sheet | Same wrap rule | Same stacked layout, more breathing room |
| Expanded | `1180–1559pt` | Same size, rarely truncates | Same | One row | Full column set | Same centered sheet | Single row, rarely wraps | Horizontal: icon, title block, spacer, status block |
| Wide | `≥ 1560pt` | Same size, content stops growing past 1120–1460pt max-width instead of stretching | Same | One row | Full column set | Same centered sheet | Single row | Same horizontal layout |

Resource detail is **one presentation at every width**: `CTXResourceInspector`,
a single tabbed `.sheet` (460–620pt wide, sized to content, capped at 680pt
tall with its own internal scroll) — not a row-anchored popover, not a
fixed-width side panel, and not separate sheets per tab. This went through
three prior designs that each broke in a different way: a 330pt persistent
side panel (clipped its action row twice), a centered `.popover` that
fought a separate YAML `.sheet` over presentation state, and then two
sibling `.sheet` cases (`.inspector` / `.yaml`) where presenting the YAML
sheet forced the inspector sheet to auto-dismiss, and that dismiss
incorrectly tore down the very selection state the YAML sheet needed —
"YAML opens then instantly closes."

The fix was to stop modeling YAML (and Logs) as *separate presentations* at
all. They're tabs inside the one inspector:

```swift
struct ClusterWorkspacePresentation: Identifiable, Equatable {
    let selection: ClusterWorkspaceResourceSelection
    var tab: CTXInspectorTab   // .overview / .yaml / .logs
}
@Published var presentation: ClusterWorkspacePresentation?
```

One `@Published` optional, one `.sheet(item:)`. Switching tabs mutates
`presentation?.tab` on the *same* value — `id` is derived only from the
resource, never the tab, so SwiftUI treats a tab switch as "update this
sheet's content," not "dismiss and present a different one." There is no
way for a "YAML flag" and an "inspector flag" to disagree, because there's
only one flag.

Trade-off, stated plainly: a `.sheet` is modal and does not dismiss on an
outside click the way a `.popover` does (Escape and the Done button still
work) — accepted deliberately, twice now, because every attempt to get
outside-click-dismiss back via a popover reintroduced a presentation-conflict
bug of one shape or another.

Any view with two densities (toolbar vs. compact toolbar, header row vs.
stacked header, chip row vs. chip stack) uses `ViewThatFits` rather than
hand-rolled width thresholds — it degrades gracefully and needs no extra
state.

Content columns are always leading-aligned, never centered — a capped
`maxWidth` combined with `alignment: .leading` on *both* the inner and outer
frame. A single `.frame(maxWidth: .infinity)` without an explicit leading
alignment centers the capped block in the remaining space, which reads as
"floating in the middle" on a wide window; this was a real bug, not a
hypothetical one — watch for it whenever a max-width cap is added.

## Typography & Spacing

- Section eyebrow labels: `size 10–11, bold`, `.secondary`, uppercased.
- Body/table text: `size 12`, `.primary`.
- Titles: `.headline` or `size 17–21, bold` for hero numbers.
- Standard content padding is `18–22pt`; card padding is `13–14pt`.
- Corner radii: `14` for panels (`CTXGlassPanel`), `12` for banners, `8–9`
  for badges, buttons, and inputs.
- Capsule badges: `9pt` horizontal / `5pt` vertical padding, tint at `10–12%`
  opacity fill with a `0.75pt` stroke at `20–24%` opacity.

## Sidebar

- Native `List(selection:)` with `.listStyle(.sidebar)` — no custom search
  field. The section list is short and fixed (cluster resource kinds), so a
  filter field added friction without adding value; removed rather than kept
  as dead weight.
- Future/disabled sections are visually de-emphasized (`.tertiary`) with a
  "Future" pill and a `.help()` explanation instead of being hidden.
- Identity footer pinned at the bottom, separated by a hairline `Divider()`.

## Cluster Workspace Header

- Header prioritizes context, cluster, provider, namespace scope, user, and
  environment.
- Long values truncate in the middle and expose full values with help/tooltips.
- Health lives in a compact menu (see "Status Indicators" below); refresh is a
  small current-screen toolbar action, not a separate button per section.
- Namespace selection is a first-class workspace scope control (popover, not
  a full sheet/window).
- Inspection mode is subtle; it should feel safe, not unfinished.

## Status Indicators

- Live status is `CTXStatusDot` (`CTXDesignSystem.swift`) — a small 8pt LED
  in a 22pt tap target — never a text badge ("Healthy") in the persistent
  header/sidebar.
  A named-text badge reads as a marketing chip; a plain colored dot reads as
  a native system indicator (Wi-Fi menu bar icon, battery LED).
- Color carries the state: green = healthy, yellow = degraded or checking,
  red = error/unreachable, gray = unknown/disconnected/not checked yet.
- The pulse ring is conditional, not constant: it only animates while a
  check is actually in flight (`isRefreshingOverview`). A healthy, settled
  dot sits still — a permanently-pulsing "healthy" indicator stops meaning
  anything and just becomes ambient noise.
- Hover shows a plain `.help()` tooltip with the one-line summary (status ·
  RBAC · last refresh). Click opens the native `Menu` with the full
  breakdown (per-resource RBAC, last refresh time, a refresh action) — this
  is the "native macOS popover/menu" surface; nothing beyond `Menu` was
  needed to satisfy that.

## Tables, Cards, and Details

Every resource screen renders through one shared `CTXResourceTable`
(`CTXResourceTable.swift`), driven by a per-kind `[CTXTableColumn]` declared
in `CTXResourceColumns.swift` (title, min/ideal/max width, alignment,
priority, `hideOnCompact`, and which single column is `isFlexible`). There
is no per-screen hand-rolled table code — Namespaces, Nodes, Workloads,
Pods, Services, Ingress, ConfigMaps, Secrets metadata, and Events all go
through the same width-resolution algorithm:

1. Below the compact breakpoint, drop `hideOnCompact` columns.
2. If even every remaining column's `minWidth` doesn't fit, drop the
   lowest-`priority` column (ties broken by later columns going first) until
   it does — that data isn't lost, it's still in the inspector.
3. Give every surviving column its `idealWidth`, then hand *all* leftover
   width to the one `isFlexible` column (usually Name, or Message for
   Events).

Step 3 keeps resource screens professional on wide monitors: the table panel
fills the workspace content width, while the flexible column absorbs the
extra room. If a narrow window cannot fit the surviving columns, horizontal
scrolling stays inside the table panel instead of breaking the page layout.

- Tables show title, count, scope, load time, local filter, and selected row.
- Use compact age values such as `10d`, `58d`, `4mo`, `2y`.
- Compact width shows fewer columns (via `hideOnCompact`/priority-dropping)
  instead of depending only on horizontal scrolling — though the
  `ScrollView(.horizontal)` safety net is still there for the rare case
  where even every ideal width doesn't fit (below the app's 980pt window
  minimum this shouldn't realistically trigger).
- Numeric/status-shaped columns (Age, Count, Keys, Restarts) are right-aligned
  via `CTXTableColumn.numeric(...)`; everything else is leading-aligned.
- Copy is a per-column flag (`CTXTableColumn.copyable: Bool`), not a single
  "one copyable column per kind" rule — Name, Namespace, an event's Object/
  Message, a service's Cluster IP/External/Ports, an ingress Hosts/Address,
  a node's IP. Never on Age, Status, Ready, Available, Restarts, Labels,
  Keys, Type, Class, Roles, Version, TLS, or Count — those are read at a
  glance, never pasted anywhere. Icons are reserved in the row's layout at
  all times (no width jump) but only visible/hit-testable on row hover
  (`CTXResourceTable`'s `hoveredRowID`) — showing every copyable column's
  icon on every row all the time would be exactly the visual noise this
  avoids. The inspector's `CTXInspectorFieldRow` uses the same allowlist
  (`copyableFieldLabels`) for the identical reason.
- The Namespace column itself only appears when the workspace is scoped to
  "All namespaces" (`CTXResourceTable.showsNamespaceColumn`) — with a single
  namespace selected, every row would repeat the same value, so the column
  earns its place only when rows can actually differ.
- Resource detail never renders inline below the table (that forces
  scrolling to see what you just clicked) and never uses a fixed-width side
  column. It's always `CTXResourceInspector`, the single tabbed sheet
  described above, at every width.
- Dismissal — Escape (`.onExitCommand`) or the Done button — always routes
  through `ClusterWorkspaceViewModel.dismissPresentation()`, which clears
  `presentation` **and** the underlying row selection together. Selecting a
  different row, changing namespace, or changing resource kind replace or
  clear `presentation` directly (see `selectResource`/`handleNamespaceChange`).
  A sheet that closes but leaves the row highlighted blue, or a dismiss that
  quietly re-opens the inspector because some other boolean was still true,
  is a bug, not a cosmetic detail — the whole point of dismissing is to "go
  back to normal," once, without a second flag undoing it.
- Rows should not carry redundant `.help()` tooltips that just repeat visible
  text (e.g. "Select <name>") — tooltips are for information that isn't
  already on screen, not hover noise.
- Filtering (`CTXSearchField` + `KubernetesResourceRow.matchesFilter`) is
  local-only, case-insensitive, and matches every cell value (name,
  namespace, status, labels, age, kind — whatever columns that resource kind
  has) plus the row id. It never triggers a kubectl call — it's a pure
  function with no reader/coordinator dependency at all. See
  `testKubernetesResourceRowLocalFiltering` and
  `testResourceRefreshCoordinatorIsolatesContexts` in
  `CTXCoreTests/main.swift`.
- Secret and ConfigMap details are metadata-oriented and never show values.

## Inspector Tabs

`CTXInspectorTabBar` is a native `Picker(.pickerStyle(.segmented))` — the
system's own tabbed-content control (System Settings panes, Xcode
inspectors), not a hand-drawn tab strip. Tabs, in order:

| Tab | Always shown? | Content |
|---|---|---|
| Overview | Yes | `CTXInspectorOverviewTab` — reference row + curated sections, via `CTXInspectorSection`/`CTXInspectorFieldRow` |
| YAML | Yes | `CTXInspectorYAMLTab` — loads lazily on first visit; shows a disabled explanation (not a broken/empty tab) when the kind doesn't support it |
| Logs | Only for Pods | `CTXInspectorLogsTab` — container picker (if multi-container), tail-length picker (100/500/1000), Reload, Copy |

The resource icon/status/title/subtitle (`CTXResourceInspectorHeader`) stays
visible above the tab bar regardless of which tab is active, so switching to
YAML or Logs never loses sight of which resource is being inspected. The
Logs tab reuses the exact same `KubernetesLogsReader` and ViewModel state as
the standalone Logs sidebar screen — no second log-fetching implementation,
just a different entry point (auto-selects the inspector's own pod instead
of asking you to pick one from a list).

## Buttons

Three owned `ButtonStyle`s in `CTXDesignSystem.swift` — never bare
`.buttonStyle(.bordered)` / `.borderless` / `.link` / `.borderedProminent`
in a workspace view. The system styles are appearance-dependent on the
surrounding material and rendered inconsistently (a flat, dark pill instead
of native chrome) in a couple of glass-panel contexts in practice; owning
the fill/stroke/opacity removes that variable entirely.

| Style | Use for | Looks like |
|---|---|---|
| `CTXPrimaryButton` | One prominent action per panel — the inspector's "Done" | Filled accent-color pill, white text |
| `CTXSecondaryButton` | Retry, Reload, Compare cached vs. live, Export JSON/CSV | Light gray fill + hairline stroke, primary text |
| `CTXInlineActionButton` | Copy name/reference/YAML, Show details, Copy diagnostics | Plain accent-color text, no fill or border |

If a button doesn't fit one of these three roles, it's probably not a
workspace action button (icon-only refresh, badge-style pickers, and card
buttons intentionally stay `.plain`/custom — they're not text CTAs).

## States and Motion

- Loading uses skeletons or small progress indicators.
- Error states show short reason, retry, copy diagnostics, and optional details.
- Empty and filtered-empty states must be concise.
- Use subtle SwiftUI transitions only (`.easeInOut(0.16–0.18s)`,
  `.opacity.combined(with: .move(edge:))`). No heavy, flashy, or distracting
  motion. Looping motion (like the status pulse) must be low-amplitude and
  low-frequency enough to read as "ambient," never "alert."
- Preserve previous data while refreshing when possible (stale-while-revalidate,
  see `CLOUD.md`).

## Accessibility

- Tooltips/help are required for truncated values and icon-only controls.
- Buttons should have stable minimum sizes and readable labels.
- Color communicates status, but text labels must still carry meaning.
