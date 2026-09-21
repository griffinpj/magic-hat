//
//  NetworkMonitor.swift
//  magic-hat
//
//  Whether the current path is metered. The catalog download refuses
//  expensive networks; without this the user would see "Downloading 0%"
//  forever on cellular with no explanation and no way to override.
//

import Foundation
import Network

@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected = true
    private(set) var isExpensive = false
    private(set) var isConstrained = false

    /// True when a large download should wait (cellular, hotspot, Low Data).
    var isMetered: Bool { isExpensive || isConstrained }

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = connected
                self.isExpensive = expensive
                self.isConstrained = constrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor", qos: .utility))
    }
}
