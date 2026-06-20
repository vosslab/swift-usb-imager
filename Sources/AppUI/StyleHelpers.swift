/// StyleHelpers.swift - shared view modifiers, layout constants, and
/// formatting helpers for the four-panel USB imager UI.
///
/// All helpers are internal to AppUI; the view layer imports this file.

import SwiftUI

// MARK: - Layout constants

enum PanelMetrics {
    /// Minimum width for the full four-panel window.
    static let windowMinWidth: CGFloat = 880
    /// Minimum height for the four-panel window.
    static let windowMinHeight: CGFloat = 420
    /// Ideal width per panel card.
    static let panelMinWidth: CGFloat = 200
    /// Inner padding inside each panel card.
    static let cardPadding: CGFloat = 18
    /// Corner radius for panel cards.
    static let cardCornerRadius: CGFloat = 22
    /// Spacing between panel cards in the horizontal stack.
    static let panelSpacing: CGFloat = 12
}

// MARK: - Per-step accent palette

/// Single source of truth for the four-panel hue progression.
///
/// The hues walk left-to-right: purple -> blue -> teal -> green.
/// All four panels import PanelAccent and pass it to PanelHeader and panelCard(tint:).
enum PanelAccent {
    /// Panel 1 Source: purple.
    static let source: Color = .purple
    /// Panel 2 Target: blue.
    static let target: Color = .blue
    /// Panel 3 Flash: teal (resting color; danger signal stays red in the confirmation dialog).
    static let flash: Color = .teal
    /// Panel 4 Verify: green.
    static let verify: Color = .green
}

// MARK: - Documentation render environment flag

/// Environment flag that switches panel cards from the live Liquid Glass
/// material to a plain opaque background for OFFSCREEN documentation renders.
///
/// Default is `false`: the interactive app keeps its unchanged Liquid Glass
/// appearance. The offscreen screenshot harness (USBImagerShots) sets this to
/// `true` because `.glassEffect` does NOT rasterize through `ImageRenderer`
/// without a live window's backing, which leaves the panel text and SF Symbol
/// icons blank in the PNGs. With the flag on, the card draws a solid charcoal
/// card carrying the same step tint and highlighting so the panel content
/// rasterizes display-independently. These renders are documentation captures,
/// not exact Liquid Glass screenshots.
private struct DocumentationRenderKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// When true, panel cards substitute a plain opaque background for the
    /// Liquid Glass material so content rasterizes offscreen. See
    /// `DocumentationRenderKey`. Public so the offscreen render harness
    /// (USBImagerShots, a separate module) can set it on `RootView`.
    public var documentationRender: Bool {
        get { self[DocumentationRenderKey.self] }
        set { self[DocumentationRenderKey.self] = newValue }
    }
}

// MARK: - Panel card modifier

/// Wraps any view in a TRUE system Liquid Glass card whose step hue is an
/// intensity gradient, not an on/off switch.
///
/// Design rationale: Apple owns the Liquid Glass material, so the card surface
/// is plain `.regular` `.glassEffect` -- robust across light/dark, accessibility
/// settings, and future Tahoe revisions. Behind the glass sits a translucent
/// charcoal depth (low-opacity black, NOT an opaque solid fill) so the cards
/// have body; inactive cards go a touch deeper for grounding. Focus is an
/// intensity gradient on the step hue: the ACTIVE card shows a loud version of
/// its own step hue (strong tint fill, strong rim, colored glow), while the
/// INACTIVE cards keep a quiet whisper of the SAME step hue (faint tint fill,
/// faint rim, plain grounding shadow). Inactive cards stay present but must not
/// compete with the active card.
///
/// `tint` is the panel's per-step accent (purple/blue/teal/green); `isActive`
/// means focused. The accent hue also lives in the panel icons and step badge.
///
/// The `documentationRender` environment flag swaps the `.glassEffect` material
/// for a solid opaque card so offscreen `ImageRenderer` captures show readable
/// text and icons; the default (false) path is the unchanged Liquid Glass app.
struct PanelCardModifier: ViewModifier {
    var tint: Color? = nil
    /// When true, the card reads as focused via a loud step hue + lift.
    var isActive: Bool = false

    /// Offscreen documentation render flag; substitutes a solid card for glass.
    @Environment(\.documentationRender) private var documentationRender
    /// Accessibility: when the user enables Reduce Transparency, also substitute
    /// the opaque charcoal card path so blur/glass is not forced on users who
    /// have requested reduced visual complexity.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// True when the opaque-card path should be used instead of Liquid Glass.
    /// Effective rule: opaque when documentationRender OR accessibilityReduceTransparency.
    private var useOpaquePath: Bool { documentationRender || reduceTransparency }

    func body(content: Content) -> some View {
        content
            .padding(PanelMetrics.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Translucent charcoal depth behind the glass; inactive a touch deeper for body.
            .background {
                RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius, style: .continuous)
                    .fill(cardDepthFill)
            }
            // Card surface: opaque path when documentationRender or accessibilityReduceTransparency;
            // true Liquid Glass otherwise (interactive app default, a11y off).
            .modifier(CardSurfaceModifier(useOpaquePath: useOpaquePath))
            // Step-hue surface tint: loud when active, subdued (same hue) when inactive.
            .overlay {
                RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius, style: .continuous)
                    .fill((tint ?? .clear).opacity(tintFillOpacity))
                    .allowsHitTesting(false)
            }
            // Rim: strong step hue when active, faint step hue when inactive.
            .overlay {
                RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius, style: .continuous)
                    .stroke((tint ?? .clear).opacity(rimOpacity), lineWidth: useOpaquePath ? 1.5 : 1)
            }
            // Lift: colored glow when active, plain grounding shadow when inactive.
            .shadow(color: isActive ? (tint ?? .clear).opacity(0.28) : Color.black.opacity(0.22), radius: isActive ? 28 : 10, x: 0, y: isActive ? 12 : 5)
            .scaleEffect(isActive ? 1.025 : 1.0)
            .animation(.snappy(duration: 0.22), value: isActive)
    }

    /// Fill drawn behind the card surface.
    ///
    /// In the interactive app this is a translucent charcoal that gives the
    /// Liquid Glass body. In the opaque path (documentationRender or
    /// accessibilityReduceTransparency) it is an OPAQUE charcoal so the card is a
    /// solid DARK surface with legible light text. The card stays dark (dark mode);
    /// legibility comes from promoting the panel text/icon foregrounds to a
    /// near-white high-contrast tone (see `CardSurfaceModifier`).
    private var cardDepthFill: Color {
        if useOpaquePath {
            // Opaque charcoal card; inactive a touch darker for grounding.
            return isActive
                ? Color(red: 0.12, green: 0.12, blue: 0.14)
                : Color(red: 0.10, green: 0.10, blue: 0.12)
        }
        // Translucent depth behind the glass; inactive a touch deeper for body.
        return Color.black.opacity(isActive ? 0.08 : 0.18)
    }

    /// Step-hue surface tint opacity. The interactive app keeps its original
    /// values (0.30 active / 0.07 inactive). The opaque path keeps the same
    /// active/inactive split so step 2 still reads loud-blue and idle Source reads
    /// quiet-purple over the dark card.
    private var tintFillOpacity: Double {
        // Same values for both paths; property retained for future per-path tuning.
        return isActive ? 0.30 : 0.07
    }

    /// Rim opacity. The opaque path uses a slightly stronger rim (drawn at a
    /// thicker line width) so the step hue stays recognizable around the dark
    /// card edge.
    private var rimOpacity: Double {
        if useOpaquePath {
            return isActive ? 0.70 : 0.22
        }
        return isActive ? 0.60 : 0.14
    }
}

/// Draws the card surface: the true Liquid Glass material when the default glass
/// path is active, or the opaque charcoal path when documentationRender or
/// accessibilityReduceTransparency is on. Split into its own modifier so the
/// `.glassEffect` call is conditional without breaking the opaque `some View`
/// body type.
private struct CardSurfaceModifier: ViewModifier {
    /// True when the opaque-card path should be used (documentationRender OR
    /// accessibilityReduceTransparency); false for the default Liquid Glass path.
    let useOpaquePath: Bool

    func body(content: Content) -> some View {
        if useOpaquePath {
            // No glass material: the opaque DARK depth fill already is the
            // surface. The three-argument `foregroundStyle` redefines what
            // `.primary`/`.secondary`/`.tertiary` resolve to for ALL descendant
            // labels, so every panel's faint `.foregroundStyle(.secondary)` header
            // and body label renders as bright light text on the dark card without
            // editing the panel views. `.colorScheme(.dark)` keeps any control
            // chrome resolving for dark.
            // This path is used both by the offscreen documentation render harness
            // (documentationRender=true) and by users who have enabled the macOS
            // "Reduce Transparency" accessibility setting.
            content
                .foregroundStyle(.white, Color.white.opacity(0.82), Color.white.opacity(0.62))
                .colorScheme(.dark)
        } else {
            // True system Liquid Glass surface (interactive app default, a11y off, unchanged).
            content
                .glassEffect(.regular, in: .rect(cornerRadius: PanelMetrics.cardCornerRadius))
        }
    }
}

extension View {
    func panelCard(tint: Color? = nil, isActive: Bool = false) -> some View {
        modifier(PanelCardModifier(tint: tint, isActive: isActive))
    }
}

// MARK: - Documentation-render button fill

/// Paints a dark, near-opaque pill behind a button label for OFFSCREEN
/// documentation renders only.
///
/// In documentation mode the card surface promotes every descendant label to
/// near-white (see `CardSurfaceModifier`). A `.bordered` button keeps its light
/// translucent tint fill, so the promoted near-white label would read
/// light-on-light. This modifier, gated on `documentationRender`, draws a dark
/// charcoal pill under the label so the near-white text keeps strong contrast,
/// matching the dark-card / light-text documentation look. The interactive app
/// (flag false) adds nothing and keeps the unchanged Liquid Glass button fill.
struct DocButtonFillModifier: ViewModifier {
    let documentationRender: Bool

    func body(content: Content) -> some View {
        if documentationRender {
            content
                // Pad so the dark pill extends past the label, covering the
                // light .bordered fill the label sits on.
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background {
                    Capsule()
                        .fill(Color(red: 0.14, green: 0.14, blue: 0.16))
                }
        } else {
            content
        }
    }
}

// MARK: - Panel header

/// Numbered badge + label row used at the top of each panel card.
///
/// The `accent` parameter drives the active badge fill color, giving each panel
/// its per-step hue. Inactive state keeps the muted secondary appearance.
struct PanelHeader: View {
    let step: Int
    let title: String
    let active: Bool
    /// Per-step semantic hue (from PanelAccent). Used for the active badge fill.
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            // Step badge: filled with the step accent when active, muted secondary when inactive.
            ZStack {
                Circle()
                    .fill(active ? accent : Color.secondary.opacity(0.35))
                    .frame(width: 26, height: 26)
                Text("\(step)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(active ? .white : .secondary)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(active ? .primary : .secondary)
            Spacer()
        }
    }
}

// MARK: - Error badge

/// High-contrast inset that renders a `CoreError` message over any glass panel.
///
/// Bare colored caption text over glass loses contrast; the dense inset preserves
/// legibility. This view
/// is used by SourcePanel, TargetPanel, and VerifyPanel so each panel renders
/// `currentError` with the same vocabulary and no per-panel copy of the styling.
///
/// The badge is visible only when `error` is non-nil; callers should still guard
/// against nil so the layout collapses cleanly (using `if let` before calling).
struct ErrorBadge: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Icon: exclamationmark on a solid fill, no dependency on glass refraction.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.white)
            // Message text: white on the dark fill, stays legible over any glass.
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Dense near-opaque red-tinted fill gives the badge body over the glass.
        // Opacity 0.82 on a pure red reads as a saturated inset without looking
        // fully opaque, keeping a light connection to the glass identity underneath.
        .background(Color.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Status badge

/// Small colored pill badge for terminal outcomes.
struct StatusBadge: View {
    enum Style { case success, warning, failure, neutral }
    let label: String
    let style: Style

    var tint: Color {
        switch style {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        case .neutral: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.2), in: Capsule())
            .foregroundStyle(tint)
    }
}
