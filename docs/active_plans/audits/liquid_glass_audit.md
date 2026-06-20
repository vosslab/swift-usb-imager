# Liquid glass best-practice audit

The four-panel USB imager UI carries a deliberate macOS 26 Liquid Glass identity:
each panel card is a `.glassEffect(.regular, in:)` surface, the four cards share
one `GlassEffectContainer` backdrop, and a dark `MeshGradient` sits behind the
glass so it has color to refract. The implementation is coherent and the glass
identity is intentional and worth keeping. This audit recommends disciplined,
in-place polish only: it does not recommend making panels opaque or swapping
glass for a solid material. The most material gaps are (1) no
`accessibilityReduceTransparency` opaque fallback for the live app, so users who
turn on Reduce Transparency still get full glass blur; (2) interactive glass-style
controls never call `.interactive()`, so glass surfaces under the pointer do not
get the system interactive response; and (3) the per-card lift shadow, surface
tint, and rim stroke are stacked on top of the glass rather than expressed through
the glass material, which risks a slightly heavy, double-treated look. Tint is
already semantic (a single `PanelAccent` palette feeds every panel), so the
semantic-tint work is small. The findings below are ordered by severity with an
in-place fix that preserves the glass.

## Findings

| ID | File and line | Snippet | Severity | In-place best-practice fix |
| --- | --- | --- | --- | --- |
| F1 | `Sources/AppUI/StyleHelpers.swift:174-197` | `CardSurfaceModifier` branches only on `documentationRender`; the live branch always calls `.glassEffect(.regular, in:)` | high | Add an `@Environment(\.accessibilityReduceTransparency)` read and, when true, render the same opaque charcoal card the documentation path already builds (reuse `cardDepthFill` opaque values) instead of `.glassEffect`. This keeps the panel layout and step tint while honoring the a11y setting in the shipping app, not just in screenshots. Maps to WP-reduce-transparency. |
| F2 | `Sources/AppUI/StyleHelpers.swift:194` | `.glassEffect(.regular, in: .rect(cornerRadius: PanelMetrics.cardCornerRadius))` | medium | The card surface is a static glass plane, but the panels respond to focus (scale, glow). Apply `.interactive()` to the glass on the active/focused card so the glass itself reacts under the pointer: `.glassEffect(.regular.interactive(), in: .rect(cornerRadius:))`. Keep the non-interactive form for inactive cards if you want them visually quieter. Maps to WP-glass-semantic-tint. |
| F3 | `Sources/AppUI/StyleHelpers.swift:113-117` | `.overlay { RoundedRectangle(...).fill((tint ?? .clear).opacity(tintFillOpacity)) }` | medium | The step hue is painted as a separate fill overlay on top of the glass rather than tinting the glass material. Move the semantic tint into the material with `.glassEffect(.regular.tint(tint), in: .rect(cornerRadius:))` so the hue refracts with the glass instead of sitting as a flat film over it. Keep the active/inactive intensity by varying tint opacity, not by stacking an extra overlay layer. Maps to WP-glass-semantic-tint. |
| F4 | `Sources/AppUI/StyleHelpers.swift:124` | `.shadow(color: isActive ? (tint ?? .clear).opacity(0.28) : Color.black.opacity(0.22), radius: isActive ? 28 : 10, ...)` | medium | A `radius: 28` colored glow plus an always-on `radius: 10` grounding shadow runs under every card, and `GlassEffectContainer` already provides elevation/separation. Lighten to one shadow with a smaller radius (active around 16, inactive around 6) and lower opacity so the glass elevation is not double-treated. Let the container, not a heavy manual shadow, carry most of the depth. Maps to WP-glass-backdrop. |
| F5 | `Sources/AppUI/RootView.swift:43-56` | `MeshGradient(... colors: [.purple.opacity(0.30), .blue.opacity(0.22), ...])` with a dark base at `RootView.swift:34` | low | The dark base plus the mesh is two stacked backdrop layers feeding the glass; refraction over a busy gradient can reduce text contrast on the glass cards. Verify text contrast over the lightest mesh cells, and if needed lower the mesh hue opacities a few points so the backdrop stays a quiet refraction source rather than competing with panel content. Maps to WP-glass-backdrop. |
| F6 | `Sources/AppUI/StyleHelpers.swift:119-122` | `.overlay { RoundedRectangle(...).stroke((tint ?? .clear).opacity(rimOpacity), lineWidth: documentationRender ? 1.5 : 1) }` | low | The rim stroke is a third stacked layer (depth fill, glass, tint fill, rim) over the same rounded rect. With the tint moved into the material (F3), keep the rim as a thin hairline only on the active card to mark focus, and drop or further soften it on inactive cards so the layering stays shallow. Maps to WP-glass-semantic-tint. |
| F7 | `Sources/AppUI/TargetPanel.swift:266-272` | `.background(isSelected ? PanelAccent.target.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))` | low | Selected disk rows sit on the glass card and use a flat tint fill for selection, while the rest of the UI is glass. For a row inside a glass card a flat low-opacity tint is acceptable, but consider giving the selected row a small nested `.glassEffect(.regular.tint(PanelAccent.target), in:)` (registered in the same container) so selection reads as a raised glass chip consistent with the card identity. Lower priority; the flat tint is legible today. Maps to WP-glass-semantic-tint. |
| F8 | `Sources/AppUI/VerifyPanel.swift:108`, `Sources/AppUI/VerifyPanel.swift:101-105` | `.background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))` wrapping `Text(sha512).font(.system(size: 8, ...))` | low | The SHA-512 block is 8 pt monospaced secondary text on a faint fill placed over a glass card; small low-contrast text over refracting glass is the hardest legibility case. Promote this digest text to at least `.caption2`, raise its contrast, or back it with a denser inset so it stays readable over the glass. Contrast of text over glass. Maps to WP-panel-error-render. |
| F9 | `Sources/AppUI/TargetPanel.swift:210-215`, `Sources/AppUI/FlashPanel.swift` error paths | `Text(error).font(.caption).foregroundStyle(.red)` over the glass card | low | Inline error text uses plain `.red` caption over the glass surface; red on a tinted/refracting backdrop can lose contrast. Render panel errors in a small backed container (a faint red-tinted inset or badge) so error state stays high-contrast over the glass rather than relying on bare colored text. Maps to WP-panel-error-render. |

## Maps to which work package

| Work package | Findings | What to do in place |
| --- | --- | --- |
| WP-reduce-transparency | F1 | Add a live `accessibilityReduceTransparency` opaque fallback in `CardSurfaceModifier`, reusing the existing opaque-card path so the shipping app honors the a11y setting, not only the screenshot harness. |
| WP-glass-semantic-tint | F2, F3, F6, F7 | Express the step hue through the glass material (`.tint`) and add `.interactive()` on focused cards; collapse the separate tint-fill and rim overlays so tint and focus live in the material, not in stacked overlays. Tint is already semantic via `PanelAccent`, so this is refinement, not a palette change. |
| WP-glass-backdrop | F4, F5 | Reduce the stacked card shadows (drop the colored 28 pt glow toward a single lighter shadow) and verify the dark-base-plus-mesh backdrop keeps text contrast; let `GlassEffectContainer` carry elevation. |
| WP-panel-error-render | F8, F9 | Raise contrast of the SHA-512 digest block and inline error text over glass by backing them in small high-contrast insets/badges rather than bare small colored text on the glass. |

## Finding counts per severity

| Severity | Count |
| --- | --- |
| high | 1 |
| medium | 3 |
| low | 5 |
| total | 9 |
