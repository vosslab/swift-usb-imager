/// TargetPanel.swift - Panel 2: USB target selection and optional checksum entry.
///
/// Lists only `availableTargets` (safe, write-worthy disks). The user taps a
/// disk row to call `selectTarget(_:)`. A refresh button calls `refreshTargets()`.
/// An expandable checksum section lets the user paste a hex string or load a
/// SHA512SUMS file via `setOfficialChecksum(_:)`.

import DiskModel
import SwiftUI

// MARK: - TargetPanel

struct TargetPanel: View {

    @Bindable var vm: AppViewModel

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
        }
        .panelCard(tint: PanelAccent.target, isActive: isCurrent)
        .disabled(!isEnabled)
    }

    // MARK: - Sub-views

    private var emptyTargetView: some View {
        // Loud icon only while Target is the current step (step 2).
        let isCurrent = vm.flashState.currentStep == 2
        return VStack(spacing: 6) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 28))
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

    private var checksumSection: some View {
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

/// One row in the target list: bus icon, name, size, and selected highlight.
private struct DiskRow: View {
    let disk: DiskDescriptor
    let isSelected: Bool

    private var busIcon: String {
        switch disk.busProtocol {
        case .usb: return "externaldrive.fill"
        case .sd: return "sdcard.fill"
        default: return "internaldrive.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: busIcon)
                // Use target accent for selected disk icon; secondary for unselected.
                .foregroundStyle(isSelected ? PanelAccent.target : Color.secondary)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 2) {
                Text(disk.bsdName)
                    .font(.subheadline.bold())
                Text(formatBytes(disk.sizeBytes))
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
