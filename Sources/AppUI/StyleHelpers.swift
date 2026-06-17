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
struct PanelCardModifier: ViewModifier {
    var tint: Color? = nil
    /// When true, the card reads as focused via a loud step hue + lift.
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(PanelMetrics.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Translucent charcoal depth behind the glass; inactive a touch deeper for body.
            .background {
                RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(isActive ? 0.08 : 0.18))
            }
            // True system Liquid Glass surface.
            .glassEffect(.regular, in: .rect(cornerRadius: PanelMetrics.cardCornerRadius))
            // Step-hue surface tint: loud when active, subdued (same hue) when inactive.
            .overlay {
                RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius, style: .continuous)
                    .fill((tint ?? .clear).opacity(isActive ? 0.30 : 0.07))
                    .allowsHitTesting(false)
            }
            // Rim: strong step hue when active, faint step hue when inactive.
            .overlay {
                RoundedRectangle(cornerRadius: PanelMetrics.cardCornerRadius, style: .continuous)
                    .stroke((tint ?? .clear).opacity(isActive ? 0.60 : 0.14), lineWidth: 1)
            }
            // Lift: colored glow when active, plain grounding shadow when inactive.
            .shadow(color: isActive ? (tint ?? .clear).opacity(0.28) : Color.black.opacity(0.22), radius: isActive ? 28 : 10, x: 0, y: isActive ? 12 : 5)
            .scaleEffect(isActive ? 1.025 : 1.0)
            .animation(.snappy(duration: 0.22), value: isActive)
    }
}

extension View {
    func panelCard(tint: Color? = nil, isActive: Bool = false) -> some View {
        modifier(PanelCardModifier(tint: tint, isActive: isActive))
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
