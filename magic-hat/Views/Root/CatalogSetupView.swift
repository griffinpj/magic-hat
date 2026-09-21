//
//  CatalogSetupView.swift
//  magic-hat
//
//  First launch only: a single screen shown before the tab bar while the
//  card catalog downloads and ingests. Blocking by default because that is
//  the honest thing on a first run — the app is far more useful once the
//  catalog is in — but escapable: "Continue in background" hands off to the
//  small status bar above the tabs. Later refreshes never show this screen.
//

import SwiftUI

struct CatalogSetupView: View {
    var controller = CatalogSyncController.shared
    let onContinue: () -> Void

    private var isWaitingForWiFi: Bool {
        if case .waitingForWiFi = controller.phase { return true }
        return false
    }

    private var failure: String? {
        if case .failed(let message) = controller.phase { return message }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: controller.phase.isActive)
                Text("Setting up your card catalog")
                    .font(.title2.weight(.semibold))
                Text("Every printing, plus official rulings, so search and details work offline. About 80 MB once; images load as you browse.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            progressCard
                .padding(.horizontal, 24)
                .padding(.top, 28)

            Spacer()

            VStack(spacing: 12) {
                if isWaitingForWiFi {
                    Button {
                        controller.allowCellular = true
                    } label: {
                        Text("Use cellular data (80 MB)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(action: onContinue) {
                    Text(failure == nil ? "Continue in background" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if controller.phase.isActive { ProgressView().controlSize(.small) }
                Text(failure ?? (controller.statusText.isEmpty ? "Starting…" : controller.statusText))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let fraction = controller.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else if controller.phase.isActive && !isWaitingForWiFi {
                ProgressView().progressViewStyle(.linear)
            }
            if isWaitingForWiFi {
                Text("You're on cellular. The download will start on Wi-Fi, or tap below to go ahead now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
