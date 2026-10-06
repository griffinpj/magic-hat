//
//  FrameRateHUD.swift
//  magic-hat
//
//  Debug builds only: a small readout of the refresh rate the display is
//  actually running at, and frames the main thread missed, from a
//  CADisplayLink asking for 120Hz. The phone is the only instrument for
//  ProMotion — Instruments can't record on it and the simulator reports
//  no frame pacing — and this answers the first question directly: is
//  the screen at 120 while the grid scrolls, or pinned at 60 (Low Power
//  Mode, Limit Frame Rate in Accessibility, or a display link the app
//  never let past 60: see CADisableMinimumFrameDurationOnPhone in
//  Info.plist)? Settings › Grid Diagnostics › Show Frame Rate.
//
//  "Missed" counts callbacks that arrived more than half a frame late:
//  the main thread's hitches. The render server's own (a GPU frame that
//  took too long) don't show here — only Xcode's hitch metric on a
//  device sees those.
//

import SwiftUI
import QuartzCore

#if DEBUG
@MainActor @Observable
final class FrameRateMonitor {
    static let shared = FrameRateMonitor()

    private(set) var hertz = 0
    private(set) var missed = 0
    private var link: CADisplayLink?
    private var frames = 0
    private var windowStart: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var expected: CFTimeInterval = 1.0 / 60.0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        frames = 0; missed = 0; windowStart = 0; last = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
        hertz = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        expected = link.targetTimestamp - link.timestamp
        if windowStart == 0 { windowStart = now; last = now; return }
        frames += 1
        if expected > 0, now - last > expected * 1.5 { missed += 1 }
        last = now
        // A readout four times a second, so the number can be read.
        if now - windowStart >= 0.25 {
            hertz = Int((Double(frames) / (now - windowStart)).rounded())
            frames = 0
            windowStart = now
        }
    }
}

/// The readout, pinned under the status bar; never over anything tappable.
struct FrameRateHUD: View {
    @AppStorage(GridDiagnostics.frameRateKey) private var shown = false
    @State private var monitor = FrameRateMonitor.shared

    var body: some View {
        if shown {
            HStack(spacing: 6) {
                Text("\(monitor.hertz) Hz")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("·")
                Text("\(monitor.missed) missed")
                    .monospacedDigit()
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.7), in: Capsule())
            .foregroundStyle(.white)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { monitor.start() }
            .onDisappear { monitor.stop() }
        }
    }
}
#endif
