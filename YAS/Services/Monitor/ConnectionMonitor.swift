import Foundation
import YASShared
import os

/// Monitor-only data source: polls sockets with libproc every 2 s (off main),
/// turns them into flows, and resolves hostnames with reverse DNS. Nothing is
/// blocked and no bytes are counted; system processes are invisible.
@MainActor
final class ConnectionMonitor {
    static let interval: Duration = .seconds(2)

    private let store: Store
    private let scanner = ConnectionScanner()
    private let dns: ReverseDNSCache
    private var tracker = FlowTracker()
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.gful.yas", category: "Monitor")
    private var scanCount = 0
    private var cpuTotal = 0.0
    private var wallTotal = 0.0
    private(set) var lastScan: ScanResult?

    var isRunning: Bool { task != nil }

    init(store: Store, dns: ReverseDNSCache = ReverseDNSCache()) {
        self.store = store
        self.dns = dns
        dns.onResolve = { [weak store] ip, host in store?.setReverseDNSHost(host, for: ip) }
    }

    func start() {
        guard task == nil else { return }
        logger.notice("Starting monitor-only connection scanning")
        let scanner = scanner
        task = Task { [weak self] in
            while !Task.isCancelled {
                let result = await scanner.scan()
                guard !Task.isCancelled, let self else { return }
                self.apply(result, at: Date())
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        tracker.reset()
        store.setHiddenSystemProcesses(0)
    }

    private func apply(_ result: ScanResult, at now: Date) {
        lastScan = result
        let update = tracker.apply(result.observations, at: now)
        store.ingest(update.appeared, source: .monitor)
        store.setOpenFlows(update.present, closed: update.closed, at: now)
        store.setHiddenSystemProcesses(result.hiddenProcesses)
        for event in update.appeared {
            if let host = dns.host(for: event.remoteIP) {
                store.setReverseDNSHost(host, for: event.remoteIP)
            } else {
                dns.request(event.remoteIP)
            }
        }
        record(result)
    }

    /// Logs the first scan and a running average every 30 scans.
    private func record(_ result: ScanResult) {
        scanCount += 1
        cpuTotal += result.cpuMilliseconds
        wallTotal += result.wallMilliseconds
        let summary = "\(result.observations.count) flows, \(result.socketsExamined) sockets, "
            + "\(result.visibleProcesses) visible / \(result.hiddenProcesses) hidden processes"
        if scanCount == 1 {
            logger.notice("First scan: \(result.cpuMilliseconds, format: .fixed(precision: 1)) ms CPU, \(result.wallMilliseconds, format: .fixed(precision: 1)) ms wall; \(summary, privacy: .public)")
        } else if scanCount % 30 == 0 {
            let count = Double(scanCount)
            logger.notice("Scan average over \(self.scanCount): \(self.cpuTotal / count, format: .fixed(precision: 1)) ms CPU, \(self.wallTotal / count, format: .fixed(precision: 1)) ms wall; last: \(summary, privacy: .public)")
        }
    }
}

/// Which data source feeds the UI (pure, tested).
enum DataSourceSelection {
    /// `-demo` wins (a development tool); then the filter when it's enabled; else monitor-only.
    static func select(demoRequested: Bool, filterEnabled: Bool) -> FlowSource {
        if demoRequested { return .demo }
        return filterEnabled ? .filter : .monitor
    }
}
