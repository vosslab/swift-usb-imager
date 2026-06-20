/// SourcePanel.swift - Panel 1: disk image source selection.
///
/// The user opens a .iso or .img file via the system file importer.
/// Once selected, the filename and size are displayed inside the card.

import SwiftUI
import UniformTypeIdentifiers
import USBImagerCore

// MARK: - Allowed import content types
//
// The file importer accepts raw disk images by extension. UTType(filenameExtension:)
// is Optional, so resolve each once at file scope with a guarded fallback to .data
// instead of force-unwrapping inline. A nil result would otherwise crash the importer;
// .data keeps the picker functional even if the type cannot be resolved.
private let isoContentType = UTType(filenameExtension: "iso") ?? .data
private let imgContentType = UTType(filenameExtension: "img") ?? .data

// MARK: - SourcePanel

struct SourcePanel: View {

    @Bindable var vm: AppViewModel

    /// Controls whether the file-picker sheet is presented.
    @State private var isImporterPresented = false

    /// Offscreen documentation render flag. Read here only to darken the
    /// "Choose Image" button fill so the doc-mode near-white label keeps strong
    /// contrast; the interactive app (flag false) is unchanged. See
    /// `StyleHelpers.swift` `CardSurfaceModifier`.
    @Environment(\.documentationRender) private var documentationRender

    var body: some View {
        // Loud/focused highlight tracks the current step only, not enablement.
        let isCurrent = vm.flashState.currentStep == 1
        return VStack(alignment: .leading, spacing: 14) {
            PanelHeader(step: 1, title: "Source", active: isCurrent, accent: PanelAccent.source)

            Spacer(minLength: 0)

            // Source image details or empty prompt
            if let url = vm.sourceURL, vm.sourceImageBytes > 0 {
                selectedFileView(url: url, bytes: vm.sourceImageBytes)
            } else {
                emptyPromptView
            }

            // Error badge: visible only for source-domain errors (file-stat failures
            // from selectSource). Errors belonging to Target or Verify are suppressed
            // here so a source error never appears mislabeled in the wrong panel.
            if let error = vm.currentError, error.domain == .source {
                ErrorBadge(message: userMessage(for: error))
            }

            Spacer(minLength: 0)

            // Open file picker button
            Button {
                isImporterPresented = true
            } label: {
                Label("Choose Image", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
                    // Documentation render only: paint a dark, near-opaque pill
                    // behind the label so the doc-mode near-white text reads with
                    // strong contrast instead of light-on-light-lavender. The
                    // interactive app (flag false) adds no background and keeps the
                    // unchanged .bordered glass fill.
                    .modifier(DocButtonFillModifier(documentationRender: documentationRender))
            }
            .buttonStyle(.bordered)
            .disabled(!vm.flashState.canSelectSource)
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [isoContentType, imgContentType],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await vm.selectSource(url) }
            }
        }
        .panelCard(tint: PanelAccent.source, isActive: isCurrent)
    }

    // MARK: - Sub-views

    private var emptyPromptView: some View {
        // Loud icon only while Source is the current step (step 1).
        let isCurrent = vm.flashState.currentStep == 1
        return VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 64))
                // Muted accent when Source is no longer the current step.
                .foregroundStyle(isCurrent ? PanelAccent.source : PanelAccent.source.opacity(0.6))
            Text("No image selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func selectedFileView(url: URL, bytes: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 28))
                // Full accent when a file is selected and the panel is active.
                .foregroundStyle(PanelAccent.source)

            Text(url.lastPathComponent)
                .font(.subheadline.bold())
                .lineLimit(3)
                .truncationMode(.middle)

            Text(formatBytes(bytes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
