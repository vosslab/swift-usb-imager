/// VerifyPanel.swift - Panel 4: terminal state display.
///
/// Renders three terminal states as first-class panels:
///   - .succeeded: device SHA-512 + checksum match outcome badge
///   - .failed: error message
///   - .cancelled: not-verified message + re-flash hint
/// Also shows an in-progress verifying view while waiting for results.
/// "Start over" resets the view model to .idle via `vm.reset()`.

import SwiftUI

// MARK: - VerifyPanel

struct VerifyPanel: View {

    @Bindable var vm: AppViewModel

    var body: some View {
        // Loud/focused highlight tracks the current step only, not enablement.
        let isCurrent = vm.flashState.currentStep == 4
        return VStack(alignment: .leading, spacing: 14) {
            PanelHeader(step: 4, title: "Verify", active: isCurrent, accent: PanelAccent.verify)

            Spacer(minLength: 0)

            switch vm.flashState {
            case .verifying(let snap):
                verifyingView(snapshot: snap)
            case .succeeded(let sha512, let outcome):
                succeededView(sha512: sha512, outcome: outcome)
            case .failed(let message):
                failedView(message: message)
            case .cancelled:
                cancelledView
            default:
                waitingView
            }

            Spacer(minLength: 0)
        }
        .panelCard(tint: PanelAccent.verify, isActive: isCurrent)
    }

    // MARK: - Sub-views

    private var waitingView: some View {
        // Loud icon only while Verify is the current step (step 4).
        let isCurrent = vm.flashState.currentStep == 4
        return VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34))
                // Muted verify accent when Verify is no longer the current step.
                .foregroundStyle(isCurrent ? PanelAccent.verify : PanelAccent.verify.opacity(0.6))
            Text("Waiting for flash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func verifyingView(snapshot: FlashProgressSnapshot) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: snapshot.fraction)
                .progressViewStyle(.linear)
                // Use the verify panel accent for the progress bar.
                .tint(PanelAccent.verify)
            Text("Verifying... \(Int(snapshot.fraction * 100))%")
                .font(.caption.bold())
            if !snapshot.speedLabel.isEmpty {
                Text(snapshot.speedLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(snapshot.transferLabel)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func succeededView(sha512: String, outcome: ChecksumMatchOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flash succeeded")
                        .font(.subheadline.bold())
                    outcomeView(outcome: outcome)
                }
            }

            // Device SHA-512 (truncated for display; full value shown on hover)
            if !sha512.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device SHA-512")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(sha512)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                .padding(6)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            startOverButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outcomeView(outcome: ChecksumMatchOutcome) -> some View {
        switch outcome {
        case .officialMatch:
            return StatusBadge(label: "Hash match", style: .success)
        case .officialMismatch:
            return StatusBadge(label: "Hash MISMATCH", style: .failure)
        case .trustedCacheHit:
            return StatusBadge(label: "Trusted cache hit", style: .success)
        case .noOfficialChecksum:
            return StatusBadge(label: "No checksum", style: .neutral)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                Text("Flash failed")
                    .font(.subheadline.bold())
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            startOverButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cancelledView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cancelled")
                        .font(.subheadline.bold())
                    StatusBadge(label: "Not verified", style: .warning)
                }
            }
            Text("The disk was not fully written. Re-flash to complete the operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            startOverButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startOverButton: some View {
        Button {
            vm.reset()
        } label: {
            Label("Start over", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
