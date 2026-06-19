/// FlashPanel.swift - Panel 3: flash control and in-progress view.
///
/// Shows the primary Flash button when a target is selected. On tap it calls
/// `requestConfirmation()`, which advances state to `.confirming` and triggers
/// a destructive confirmation sheet naming the exact target (display name +
/// device path). On sheet confirmation, `startFlash()` is called inside a
/// Task. While `.flashing` or `.verifying`, shows a progress ring, speed,
/// transfer label, and a Cancel button.

import SwiftUI

// MARK: - FlashPanel

struct FlashPanel: View {

    @Bindable var vm: AppViewModel

    /// Whether the destructive confirmation sheet is presented.
    @State private var isConfirmationPresented = false

    var body: some View {
        // Loud/focused highlight tracks the current step only, not enablement.
        let isCurrent = vm.flashState.currentStep == 3
        return VStack(alignment: .leading, spacing: 14) {
            PanelHeader(step: 3, title: "Flash", active: isCurrent, accent: PanelAccent.flash)

            Spacer(minLength: 0)

            switch vm.flashState {
            case .flashing(let snap):
                progressView(snapshot: snap, label: "Writing to disk...")
            case .verifying(let snap):
                progressView(snapshot: snap, label: "Verifying...")
            case .targetSelected(_, let target):
                readyView(target: target)
            case .confirming(_, let target):
                // Advance to confirming sheet as soon as state enters .confirming.
                readyView(target: target)
                    .onAppear { isConfirmationPresented = true }
            default:
                idleView
            }

            Spacer(minLength: 0)
        }
        .panelCard(tint: PanelAccent.flash, isActive: isCurrent)
        // Destructive confirmation sheet
        .confirmationDialog(
            confirmationTitle,
            isPresented: $isConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Flash \(targetShortLabel)", role: .destructive) {
                Task { await vm.startFlash() }
            }
            Button("Cancel", role: .cancel) {
                // Revert from .confirming back to .targetSelected by re-selecting.
                if case .confirming(_, let target) = vm.flashState {
                    vm.selectTarget(target.disk)
                }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - Sub-views

    private var idleView: some View {
        // Loud icon only while Flash is the current step (step 3).
        let isCurrent = vm.flashState.currentStep == 3
        return VStack(spacing: 12) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 64))
                // Muted teal when Flash is no longer the current step.
                .foregroundStyle(isCurrent ? PanelAccent.flash : PanelAccent.flash.opacity(0.6))
            Text("Select a target first")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func readyView(target: TargetInfo) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 34))
                    // Full flash accent when ready to write.
                    .foregroundStyle(PanelAccent.flash)
                Text("Ready to flash")
                    .font(.subheadline.bold())
                Text(target.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            Button {
                vm.requestConfirmation()
            } label: {
                Label("Flash", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PanelAccent.flash)
        }
    }

    private func progressView(snapshot: FlashProgressSnapshot, label: String) -> some View {
        VStack(spacing: 14) {
            // Circular progress ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: snapshot.fraction)
                    // Flash accent on the progress ring arc.
                    .stroke(PanelAccent.flash, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: snapshot.fraction)
                VStack(spacing: 2) {
                    Text("\(Int(snapshot.fraction * 100))%")
                        .font(.title3.bold())
                    Text(snapshot.phaseLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 88, height: 88)

            // Speed and transfer
            if !snapshot.speedLabel.isEmpty {
                Text(snapshot.speedLabel)
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.primary)
            }
            Text(snapshot.transferLabel)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            // Cancel button
            Button {
                Task { await vm.cancel() }
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Confirmation dialog strings

    /// Returns the target display label for destructive button name.
    private var targetShortLabel: String {
        switch vm.flashState {
        case .confirming(_, let target):
            // Name the exact device: displayName includes (diskN)
            return target.displayName
        default:
            return "target"
        }
    }

    /// Title for the confirmation dialog - names the source and target.
    private var confirmationTitle: String {
        switch vm.flashState {
        case .confirming(let sourceURL, let target):
            let filename = sourceURL.lastPathComponent
            return "Write \"\(filename)\" to \(target.displayName)?"
        default:
            return "Confirm Flash"
        }
    }

    /// Body message for the confirmation dialog.
    private var confirmationMessage: String {
        switch vm.flashState {
        case .confirming(_, let target):
            let path = target.disk.rawDevicePath
            return "This will permanently erase all data on \(target.displayName) (\(path))." +
                   " This action cannot be undone."
        default:
            return "All data on the selected disk will be permanently erased."
        }
    }
}
