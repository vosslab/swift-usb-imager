/// RootView.swift - top-level layout for the four-panel USB imager UI.
///
/// Arranges the four panels side-by-side in a horizontal stack inside a
/// `GlassEffectContainer` so all panel cards share one Liquid Glass blur
/// backdrop. The window is resizable with a sensible minimum size.
///
/// Liquid Glass API used:
///   - `GlassEffectContainer { ... }` - shared backdrop for all panels.
///   - `.glassEffect(in: .rect(cornerRadius:))` - per-panel card surface
///     (applied via `panelCard()` in StyleHelpers.swift).

import SwiftUI

// MARK: - RootView

public struct RootView: View {

    @State private var vm: AppViewModel

    /// Offscreen documentation render flag. When true, the shared
    /// `GlassEffectContainer` backdrop is dropped (it does not rasterize through
    /// `ImageRenderer` without a live window) and the panels draw as solid cards.
    /// Default false keeps the interactive Liquid Glass app appearance unchanged.
    @Environment(\.documentationRender) private var documentationRender

    public init(vm: AppViewModel) {
        _vm = State(initialValue: vm)
    }

    public var body: some View {
        ZStack {
            // Dark base UNDER the mesh so the colored backdrop never washes out
            // and white panel text stays readable.
            Color(red: 0.06, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            // Colored MeshGradient backdrop BEHIND the glass. A uniform dark
            // charcoal window gave the Liquid Glass nothing to refract; this
            // muted mesh walks the four step hues left-to-right (purple ->
            // blue -> teal -> green) so the glass has color and contrast to
            // blur and refract. Kept DARK so it reads as a backdrop, not a
            // feature, and text stays readable.
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5, 0.5], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ],
                colors: [
                    .purple.opacity(0.30), .blue.opacity(0.22), .teal.opacity(0.26),
                    .indigo.opacity(0.20), .black.opacity(0.55), .green.opacity(0.18),
                    .purple.opacity(0.22), .black.opacity(0.5), .green.opacity(0.24)
                ]
            )
            .ignoresSafeArea()

            // Interactive app: share one Liquid Glass backdrop across panels.
            // Documentation render: drop the container, which does not rasterize
            // offscreen, and let the panels draw as solid cards instead.
            if documentationRender {
                panelStack
            } else {
                GlassEffectContainer {
                    panelStack
                }
            }
        }
        .frame(
            minWidth: PanelMetrics.windowMinWidth,
            minHeight: PanelMetrics.windowMinHeight
        )
    }

    /// The four panels side by side. Wrapped in a `GlassEffectContainer` for the
    /// interactive app; drawn bare for offscreen documentation renders.
    private var panelStack: some View {
        HStack(alignment: .top, spacing: PanelMetrics.panelSpacing) {
            SourcePanel(vm: vm)
                .frame(minWidth: PanelMetrics.panelMinWidth)

            panelDivider

            TargetPanel(vm: vm)
                .frame(minWidth: PanelMetrics.panelMinWidth)

            panelDivider

            FlashPanel(vm: vm)
                .frame(minWidth: PanelMetrics.panelMinWidth)

            panelDivider

            VerifyPanel(vm: vm)
                .frame(minWidth: PanelMetrics.panelMinWidth)
        }
        .padding(PanelMetrics.panelSpacing)
    }

    /// Subtle vertical divider between panels.
    private var panelDivider: some View {
        Divider()
            .opacity(0.3)
    }
}
