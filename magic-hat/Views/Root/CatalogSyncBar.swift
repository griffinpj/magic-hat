//
//  CatalogSyncBar.swift
//  magic-hat
//
//  A thin status strip that rides above whatever tab the user is on while the
//  card catalog downloads and ingests. Deliberately non-modal: the app stays
//  fully usable on the data it already has, and the bar just narrates what is
//  happening in the background.
//

import SwiftUI

struct CatalogSyncBar: View {
    var controller = CatalogSyncController.shared

    var body: some View {
        if controller.phase.isActive {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.statusText)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                // Determinate while downloading, indeterminate while ingesting
                // (the line count isn't known until the file is read).
                if let fraction = controller.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: controller.phase.isActive)
        }
    }
}
