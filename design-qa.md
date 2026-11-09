# Design QA — Ringmaster visual system and project contents

## Source of truth

- Live reference: `http://localhost:3002/projects/ringmaster-studio`
- Reference component: `/Users/djodonnell/Documents/Development/ringmaster/src/web/app/components/ds/rail.tsx`
- Reference styles: `/Users/djodonnell/Documents/Development/ringmaster/src/web/app/styles/datashow.css`
- Reference Mantine theme: `/Users/djodonnell/Documents/Development/ringmaster/src/web/app/theme/datashow.ts`
- Reference route placement: `/Users/djodonnell/Documents/Development/ringmaster/src/web/app/routes/projects.$projectId.tsx`
- Reference alert component: `/Users/djodonnell/Documents/Development/ringmaster/src/web/app/components/projects/ProjectRecordIndex.tsx`
- Reference hairline card component: `/Users/djodonnell/Documents/Development/ringmaster/src/web/app/components/ds/cards.tsx`
- Reference record carousel: `/Users/djodonnell/Documents/Development/ringmaster/src/web/app/components/projects/ProjectDocumentCarousel.tsx`
- Reference record carousel styles: `/Users/djodonnell/Documents/Development/ringmaster/src/web/app/components/projects/ProjectWorkspace.css`
- Agent Boards verification route: `http://localhost:4173/projects/45b6473a-788f-4fb2-9390-8b4451906a07`

## Correct implementation

- `apps/web/src/theme.ts` is byte-for-byte identical to Ringmaster's `theme/datashow.ts`.
- `apps/web/src/datashow.css` is byte-for-byte identical to Ringmaster's `styles/datashow.css`.
- `MantineProvider` uses Ringmaster's `datashowTheme` and `datashowCssVariablesResolver` directly.
- The HTML document loads Ringmaster's exact IBM Plex Sans, Serif, and Mono families, including the same weights and italic faces.
- Agent Boards' previous duplicate palette and font declarations were removed. Existing selectors now consume the copied `--c-*` and `--f-*` tokens.
- Ad-hoc CSS hex colours were removed from the application stylesheet in favour of copied Datashow or Mantine palette tokens.

- The Contents rail now renders Mantine's `TableOfContents` through `GutterRail`.
- Mantine scroll-spy reads `[data-rail-anchor]` targets and owns the active state.
- The rail is a sibling of the project content but is fixed outside the page's layout flow, so it cannot reduce the central content width.
- When the viewport has room for the full 1380px page plus its gutter, the 230px control starts at the page's outer right edge. The page's own 44px padding supplies the gap from content.
- When the viewport cannot hold that external gutter, the rail disappears instead of consuming page width.
- The previous custom navigation, React portal, shell-level rail target, and duplicate mobile ToC were removed.

- Project alerts now use Ringmaster's strip structure rather than the previous bordered button treatment: inset background, 3px state edge, 10px × 16px padding, 26px lower spacing, 12px status copy, and 10px uppercase action copy.
- The running-work strip keeps Ringmaster's teal working-state dot; the attention strip uses the Ringmaster alert colour and contains no unrelated warning icon.
- The project brief now uses Ringmaster's exact 15px IBM Plex Serif setting with 1.55 line height and 10px top spacing. The previous 23px treatment was removed.
- The delivery-record panel was removed. The supporting card now uses Ringmaster's hairline-card structure and presents the Agent Boards source repository, branch, management mode, and visibility.
- The source-repository heading matches Ringmaster's 19px IBM Plex Serif italic card heading.
- The project identity row contains only the project title and a right-aligned `UPDATED` timestamp. The status badge, owner label, and board-name label have been removed.
- The attention section now uses Ringmaster's exact `SectionHead` and `HairCard` geometry: a 1.7fr/1fr title-and-standfirst grid, 36px heading, 6px alert dot, 13.5px item title, 9px reason line, 10.5px state label, and the mono card footer.
- The former boxed warning icon and redundant item key/type decoration were removed from attention items.
- The current-delivery flow card no longer has the redundant `FLOW / Work across delivery stages` header rail.
- `OPEN BOARD →` now lives in a dedicated bottom card rail, paired with Ringmaster's open-items-per-stage caption.
- Recent activity now sits directly below the flow card as Ringmaster's unboxed manifest table: italic 19px heading, flush-right `VIEW ALL` control, 6px status dots, 13px summaries, 9px mono metadata and timestamps, and hairline-separated rows.
- Delivery health now uses four independent Ringmaster hairline cards rather than the previous joined metric grid. Each card has the source 19px serif-italic heading, 20px figure, 2px progress rule where applicable, and mono footer rail.
- The health grid presents four equal columns on the wide Agent Boards canvas, two columns below 1100px, and one stacked column below 760px.
- Project record now uses Embla carousels for project artefacts and registers, with Ringmaster's document previews, card hierarchy, previous/next controls, snap counter, and four visible cards at the default wide viewport.
- Embla's elastic wheel-gesture plugin was removed. Horizontal wheel and trackpad gestures now advance one clamped snap per gesture, while `overscroll-behavior-x: contain` prevents browser-level horizontal overscroll at the rail edges.
- The durable record set includes the project brief, PRD, architecture document, risk register, and issue register. The project brief description explicitly identifies it as an AI summary of the supplied brief.
- The Board now uses the same 1380px centred measure as Overview by default and exposes a single accessible expand/collapse icon for full-viewport working mode.
- Board header chrome is limited to `Kanban Delivery Board` and that width control. Breadcrumbs, segmented navigation, and buttons all disable accidental text selection.

## Browser evidence

Verified at 1940 × 900 CSS pixels:

- Central page: x=280px, width=1380px.
- Central content: x=324px, width=1292px.
- Floating ToC: x=1660px, width=230px, `position: fixed`.
- Project page has no grid columns, so the ToC does not alter central content width.

Verified at 1280 × 720 CSS pixels:

- `.mantine-TableOfContents-root` count: 1.
- Legacy custom ToC element count: 0.
- Central content: x=44px, width=1192px.
- ToC display: `none`.
- Project page grid columns: none.

Theme verification in the running browser:

- Body: IBM Plex Sans, 14.5px, `rgb(26, 24, 21)`.
- Headings: IBM Plex Sans, weight 500.
- IBM Plex Sans, Mono, and Serif all report loaded through `document.fonts`.
- `--c-canvas`: `#ffffff`; `--c-ink`: `#1a1815`; `--c-accent`: `#226f74`; `--c-alert`: `#8b2440`.
- Mantine body and text variables resolve to the same canvas and ink values.

Project-detail verification against Ringmaster at the same 1280 × 720 CSS-pixel viewport:

- Alert strip: 38px high in both applications; `10px 16px` padding; 3px alert edge; `rgb(244, 243, 240)` inset background; 26px lower spacing.
- Alert message: 12px IBM Plex Mono, 0.08em tracking; action: 10px IBM Plex Mono, 0.08em tracking, uppercase.
- Project brief: 15px IBM Plex Serif with 23.25px computed line height in both applications.
- Repository heading: 19px IBM Plex Serif italic with 28.5px computed line height in both applications.
- Repository link: 12px IBM Plex Mono; repository state: 9px IBM Plex Mono with 0.08em tracking.
- Attention heading: 36px with 37.8px computed line height in both applications.
- Attention card: 112.75px high in both applications for the single-item state, with the same 1px hairline border.
- Attention item title: 13.5px with 20.25px computed line height in both applications.
- Delivery health: four 283px cards in one row within the 1192px content width; all four cards compute to the same 180px height.
- At 900px viewport width, delivery health computes to two 407.6px columns; at 700px, it computes to one 649.6px column.
- Project artefacts: four full cards visible at 1280px. Embla next control advances the snap counter from `1 / 5` to `2 / 5` and moves the first slide off-canvas.
- At 1920px, the Board computed to x=270px and width=1380px by default; expanded mode computed to x=0px and width=1920px; collapsing restored the centred values.
- At the final project-artefact snap (`5 / 5`), an aggressive 20-page horizontal wheel gesture produced 0px rail movement and left the next control disabled.
- Project record API returned the five required durable records; MCP `tools/list` exposed `list_project_records`, `get_project_record`, and `upsert_project_record`.
- Browser console errors: none.

## Validation

- TypeScript typecheck: passed.
- Production build: passed.
- Browser console errors/warnings: none.
- Theme source SHA-256 values match Ringmaster exactly.
- final result: passed.

## Superseded attempts

Earlier custom CSS, body-portal, and shell-grid approaches did not match the Ringmaster component architecture and are not part of the final implementation.
