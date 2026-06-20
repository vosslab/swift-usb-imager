/// TargetPanel.swift - Panel 2: USB target selection and optional checksum entry.
///
/// Lists only `availableTargets` (safe, write-worthy disks). The user taps a
/// disk row to call `selectTarget(_:)`. A refresh button calls `refreshTargets()`.
/// An expandable checksum section lets the user paste a hex string or load a
/// SHA512SUMS file via `setOfficialChecksum(_:)`.

import DiskModel
import SwiftUI
import USBImagerCore

// MARK: - TargetPanel

struct TargetPanel: View {

    @Bindable var vm: AppViewModel

    /// Offscreen documentation render flag. When true, the interactive checksum
    /// controls (Button/TextField) are replaced with a plain static label because
    /// AppKit controls rasterize as a filled yellow "disabled" bar with a red
    /// no-entry glyph through `ImageRenderer` (see `checksumSection`). The
    /// interactive app (flag false) is unchanged.
    @Environment(\.documentationRender) private var documentationRender

    /// Controls the SHA512SUMS file importer sheet.
    @State private var isChecksumFileImporterPresented = false

    /// Local state for the pasted checksum text field.
    @State private var pastedHex: String = ""

    /// Whether the checksum entry section is expanded.
    @State private var checksumExpanded: Bool = false

    /// Panel enabled when a source has been selected and the job is not active.
    private var isEnabled: Bool {
        switch vm.flashState {
        case .sourceSelected, .targetSelected:
            return true
        default:
            return false
        }
    }

    var body: some View {
        // Loud/focused highlight tracks the current step only, not enablement.
        let isCurrent = vm.flashState.currentStep == 2
        return VStack(alignment: .leading, spacing: 10) {
            // Header with refresh affordance
            HStack {
                PanelHeader(step: 2, title: "Target", active: isCurrent, accent: PanelAccent.target)
                Spacer()
                // Documentation render: the live Button rasterizes through
                // ImageRenderer as a filled yellow disabled glyph, so show the
                // plain refresh icon instead. Interactive app keeps the Button.
                if documentationRender {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await vm.refreshTargets() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isEnabled)
                    .help("Refresh disk list")
                }
            }

            Divider()

            // Disk list
            if vm.availableTargets.isEmpty {
                emptyTargetView
            } else {
                diskListView
            }

            Divider()

            // Collapsible checksum entry
            checksumSection

            // Error badge: visible only for target-domain errors (helper unavailable,
            // flash-write failures). Source and Verify domain errors are suppressed
            // here so only contextually relevant errors appear in this panel.
            if let error = vm.currentError, error.domain == .target {
                ErrorBadge(message: userMessage(for: error))
            }
        }
        .panelCard(tint: PanelAccent.target, isActive: isCurrent)
        .disabled(!isEnabled)
    }

    // MARK: - Sub-views

    private var emptyTargetView: some View {
        // Loud icon only while Target is the current step (step 2).
        let isCurrent = vm.flashState.currentStep == 2
        return VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 64))
                // Muted accent when Target is no longer the current step.
                .foregroundStyle(isCurrent ? PanelAccent.target : PanelAccent.target.opacity(0.6))
            Text("No removable disks found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var diskListView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 4) {
                ForEach(vm.availableTargets) { disk in
                    DiskRow(
                        disk: disk,
                        // Route the primary label through the core displayName helper
                        // so the GUI and CLI share one canonical format.
                        primaryLabel: vm.displayName(for: disk),
                        isSelected: vm.selectedTarget?.bsdName == disk.bsdName
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        vm.selectTarget(disk)
                    }
                }
            }
        }
        .frame(maxHeight: 180)
    }

    @ViewBuilder
    private var checksumSection: some View {
        // Documentation render: the interactive Button/TextField below rasterize
        // through ImageRenderer as a filled yellow "disabled" bar with a red
        // no-entry glyph. Substitute a plain static label so the doc screenshot
        // reads cleanly. The interactive app (flag false) keeps the live controls.
        if documentationRender {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                Text("Optional checksum")
                    .font(.caption.bold())
                Spacer()
            }
            .foregroundStyle(.secondary)
        } else {
            interactiveChecksumSection
        }
    }

    private var interactiveChecksumSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expand/collapse toggle
            Button {
                checksumExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: checksumExpanded ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                    Text("Optional checksum")
                        .font(.caption.bold())
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)

            if checksumExpanded {
                // Paste hex field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paste SHA-512 (128 hex chars)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("a1b2c3...", text: $pastedHex)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: pastedHex) { _, hex in
                                if hex.count == 128 {
                                    vm.setOfficialChecksum(.pastedHex(hexString: hex))
                                }
                            }
                        if !pastedHex.isEmpty {
                            Button {
                                pastedHex = ""
                                vm.clearOfficialChecksum()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                // Load SHA512SUMS file
                Button {
                    isChecksumFileImporterPresented = true
                } label: {
                    Label("Load SHA512SUMS file", systemImage: "doc.text")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .fileImporter(
                    isPresented: $isChecksumFileImporterPresented,
                    allowedContentTypes: [.text, .plainText],
                    allowsMultipleSelection: false
                ) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    // The view model reads the file so a read failure surfaces as an error.
                    vm.setOfficialChecksumFile(at: url)
                }

                // Validation error
                if let error = vm.checksumInputError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Accepted checksum indicator
                if vm.expectedDigest != nil && vm.checksumInputError == nil {
                    Label("Checksum accepted", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

// MARK: - DiskRow

/// One row in the target list: bus icon, human identity, volume/BSD name, and
/// selected highlight.
///
/// Layout:
///   PRIMARY   - vendor + model + size, via core `displayName(for:)`.
///               Example: "SanDisk Ultra 32.0 GB"
///   SECONDARY - volume label (when present) followed by the BSD name.
///               Example: "UNTITLED - disk4"  or just "disk4" when unmounted.
private struct DiskRow: View {
    let disk: DiskDescriptor
    /// Human-readable primary label, composed by the core `displayName(for:)` helper.
    let primaryLabel: String
    let isSelected: Bool

    private var busIcon: String {
        switch disk.busProtocol {
        case .usb: return "externaldrive.fill"
        case .sd: return "sdcard.fill"
        default: return "internaldrive.fill"
        }
    }

    /// Secondary line: volume label (if any) plus the BSD name as fallback anchor.
    private var secondaryLabel: String {
        let volumeLabel = disk.volumeLabel.trimmingCharacters(in: .whitespaces)
        if volumeLabel.isEmpty {
            // No volume label: just show the BSD name so the operator always has
            // a unique identifier even for unmounted or unlabeled media.
            return disk.bsdName
        }
        // Volume label present: "UNTITLED - disk4"
        return "\(volumeLabel) - \(disk.bsdName)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: busIcon)
                // Use target accent for selected disk icon; secondary for unselected.
                .foregroundStyle(isSelected ? PanelAccent.target : Color.secondary)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 2) {
                // Primary: human identity (vendor + model + size).
                Text(primaryLabel)
                    .font(.subheadline.bold())
                // Secondary: volume label and BSD name for confirmation.
                Text(secondaryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PanelAccent.target)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            isSelected
                ? PanelAccent.target.opacity(0.15)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
