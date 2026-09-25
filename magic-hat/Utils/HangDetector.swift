//
//  HangDetector.swift
//  magic-hat
//
//  Debug-only watchdog. A background thread pings the main queue; when the
//  main thread fails to answer within `threshold`, the watchdog suspends
//  it for a moment, reads its registers, walks the frame-pointer chain, and
//  resumes it. When the hang ends, the duration and the sampled stack are
//  logged. Run from Xcode, reproduce the stall, filter the console for
//  MAIN THREAD HANG — evidence instead of guesses.
//
//  Mach thread APIs, not a signal: lldb stops the process on a signal, so
//  a signal-based sampler made the app appear to hang at launch under the
//  debugger. Nothing allocates while the main thread is suspended (it may
//  hold the malloc lock); addresses go into a preallocated buffer and are
//  symbolicated after the resume.
//
//  Not compiled into release builds.
//

#if DEBUG
import Foundation
import Darwin
import os

enum HangDetector {
    private static let maxFrames = 96
    nonisolated(unsafe) private static var mainThread: mach_port_t = 0
    nonisolated(unsafe) private static var stackLow: UInt = 0
    nonisolated(unsafe) private static var stackHigh: UInt = 0
    nonisolated(unsafe) private static let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
    nonisolated(unsafe) private static var frameCount = 0
    private static let log = Logger(subsystem: "magic-hat", category: "hang")

    /// `UITEST_HANG_LOG=<path>`: every report is also appended to that
    /// file as one JSON line, so a UI test can count the stalls its flow
    /// caused and fail on any. `UITEST_HANG_THRESHOLD` (seconds) lowers
    /// the bar for such a run — 0.1s is six dropped frames.
    nonisolated(unsafe) private static var logFile: URL?
    private static let logQueue = DispatchQueue(label: "magic-hat.hang-log")

    /// Call once, on the main thread, at launch.
    static func start(threshold defaultThreshold: TimeInterval = 0.4) {
        guard mainThread == 0 else { return }
        let env = ProcessInfo.processInfo.environment
        let threshold = env["UITEST_HANG_THRESHOLD"].flatMap(Double.init) ?? defaultThreshold
        if let path = env["UITEST_HANG_LOG"], !path.isEmpty {
            logFile = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: logFile!.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let me = pthread_self()
        mainThread = pthread_mach_thread_np(me)
        // The stack grows down from stackaddr; keep the frame walk inside it.
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackLow = stackHigh &- UInt(pthread_get_stacksize_np(me))

        let thread = Thread { watchdog(threshold: threshold) }
        thread.name = "hang-watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
        log.notice("HangDetector armed (threshold \(threshold, format: .fixed(precision: 2))s)")
    }

    /// The ping cadence scales with the threshold. A fixed quarter-second
    /// gap between pings meant a stall shorter than that was only seen if
    /// it happened to overlap a ping — at a 100ms bar, most 100–200ms
    /// stalls went unreported.
    private static func watchdog(threshold: TimeInterval) {
        let gap = min(0.25, threshold / 2)
        let step = min(0.05, threshold / 5)
        while true {
            let answered = DispatchSemaphore(value: 0)
            let start = Date()
            DispatchQueue.main.async { answered.signal() }

            var sampled = false
            while answered.wait(timeout: .now() + step) == .timedOut {
                if !sampled, Date().timeIntervalSince(start) > threshold {
                    sample()
                    sampled = true
                }
            }

            let elapsed = Date().timeIntervalSince(start)
            if sampled, elapsed > threshold {
                let stack = symbolicated()
                let line = String(format: "⚠️ MAIN THREAD HANG %.2fs\n", elapsed) + stack
                log.error("\(line, privacy: .public)")
                print(line)
                append(duration: elapsed, stack: stack)
            }
            Thread.sleep(forTimeInterval: gap)
        }
    }

    private static func append(duration: TimeInterval, stack: String) {
        guard let logFile else { return }
        let record: [String: Any] = [
            "t": Date().timeIntervalSince1970, "duration": duration,
            "frames": stack.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) },
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(0x0A)
        logQueue.async {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: Sampling

    /// Pointer-authentication bits live in the high bits on arm64e; user
    /// addresses fit well under this mask, so stripping is a mask.
    private static let addressMask: UInt = 0x0000_007F_FFFF_FFFF

    private static func sample() {
        frameCount = 0
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { ptr in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            #if _ptrauth(_arm64e)
            let pc = UInt(bitPattern: state.__opaque_pc) & addressMask
            let lr = UInt(bitPattern: state.__opaque_lr) & addressMask
            var fp = UInt(bitPattern: state.__opaque_fp) & addressMask
            #else
            let pc = UInt(state.__pc) & addressMask
            let lr = UInt(state.__lr) & addressMask
            var fp = UInt(state.__fp) & addressMask
            #endif
            push(pc)
            push(lr)
            // Each frame: [fp] = caller's fp, [fp + 8] = return address.
            while frameCount < maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp & 0xF == 0 {
                let raw = UnsafePointer<UInt>(bitPattern: fp)!
                let nextFP = raw.pointee & addressMask
                let ret = raw.advanced(by: 1).pointee & addressMask
                guard ret != 0 else { break }
                push(ret)
                guard nextFP > fp else { break }   // stacks grow down; the chain must go up
                fp = nextFP
            }
        }
        thread_resume(mainThread)
        #endif
    }

    private static func push(_ address: UInt) {
        guard frameCount < maxFrames, address != 0 else { return }
        frames[frameCount] = address
        frameCount += 1
    }

    private static func symbolicated() -> String {
        guard frameCount > 0 else { return "  (no sample captured)" }
        var lines: [String] = []
        for i in 0..<frameCount {
            let address = frames[i]
            var info = Dl_info()
            if let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0, let name = info.dli_sname {
                let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
                lines.append("  \(i)  \(image)  \(String(cString: name))")
            } else {
                lines.append("  \(i)  0x\(String(address, radix: 16))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
