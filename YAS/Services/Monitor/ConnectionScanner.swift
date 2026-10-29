import Darwin
import Foundation
import YASShared
import Security

/// One connected socket of a process, with the process's identity.
struct SocketObservation: Hashable, Sendable {
    /// "pid:start" so a reused pid is a different process.
    let processKey: String
    let pid: Int32
    let app: AppIdentity
    let socket: ParsedSocket
    let direction: FlowDirection
}

struct ScanResult: Sendable {
    let observations: [SocketObservation]
    /// Processes whose sockets we may not read (root / other users).
    let hiddenProcesses: Int
    let visibleProcesses: Int
    let socketsExamined: Int
    let cpuMilliseconds: Double
    let wallMilliseconds: Double
}

/// Reads every readable process's sockets through libproc. Runs on its own actor
/// (off the main thread); `scan()` is synchronous inside, so the CPU clock below
/// measures one thread.
actor ConnectionScanner {
    private var identities: [String: AppIdentity] = [:]
    private let ownUID = getuid()

    func scan() -> ScanResult {
        let wallStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)

        var hidden = 0
        var visible = 0
        var examined = 0
        var listeningPorts: Set<Int> = []
        var connected: [(pid: Int32, sockets: [ParsedSocket])] = []

        for pid in Self.allPIDs() where pid > 0 {
            guard let fds = Self.fileDescriptors(of: pid) else {
                if errno == EPERM { hidden += 1 }
                continue
            }
            visible += 1
            var sockets: [ParsedSocket] = []
            for fd in fds where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                examined += 1
                guard let info = Self.socketInfo(pid: pid, fd: fd.proc_fd), let parsed = SocketParser.parse(info) else { continue }
                if parsed.isListening {
                    listeningPorts.insert(parsed.localPort)
                } else {
                    sockets.append(parsed)
                }
            }
            if !sockets.isEmpty { connected.append((pid, sockets)) }
        }

        var observations: [SocketObservation] = []
        var liveKeys: Set<String> = []
        for (pid, sockets) in connected {
            let key = "\(pid):\(Self.startTime(of: pid))"
            liveKeys.insert(key)
            guard let app = identity(for: pid, key: key) else { continue }
            for socket in sockets {
                let inbound = socket.proto == .tcp && listeningPorts.contains(socket.localPort)
                observations.append(SocketObservation(
                    processKey: key, pid: pid, app: app, socket: socket, direction: inbound ? .inbound : .outbound))
            }
        }
        identities = identities.filter { liveKeys.contains($0.key) }

        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
        let wall = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wallStart) / 1_000_000
        return ScanResult(
            observations: observations, hiddenProcesses: hidden, visibleProcesses: visible,
            socketsExamined: examined, cpuMilliseconds: cpu, wallMilliseconds: wall)
    }

    // MARK: - Identity (cached per process)

    private func identity(for pid: Int32, key: String) -> AppIdentity? {
        if let cached = identities[key] { return cached }
        guard let resolved = Self.resolveIdentity(pid: pid) else { return nil }
        identities[key] = resolved
        return resolved
    }

    /// Executable path plus the running code's signature (by pid), like the
    /// extension reports from an audit token.
    static func resolveIdentity(pid: Int32) -> AppIdentity? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        guard !path.isEmpty else { return nil }

        var info: CodeSignature.Info?
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code {
            info = CodeSignature.runningInformation(for: code)
        }
        if info == nil { info = CodeSignature.signingInformation(at: URL(fileURLWithPath: path)) }

        return AppIdentity(
            bundleID: innermostBundleIdentifier(forExecutablePath: path),
            signingID: info?.signingID,
            teamID: info?.teamID,
            executablePath: path,
            isAppleSigned: info?.isAppleSigned ?? false,
            isValidlySigned: info?.isValid ?? false)
    }

    /// Bundle ID of the .app whose executable this is (helpers keep their own ID).
    static func innermostBundleIdentifier(forExecutablePath path: String) -> String? {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
            url.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - libproc

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    /// Nil (with errno set) when the process can't be read.
    static func fileDescriptors(of pid: Int32) -> [proc_fdinfo]? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return nil }
        return Array(fds.prefix(Int(bytes) / stride))
    }

    static func socketInfo(pid: Int32, fd: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let read = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        return read == size ? info : nil
    }

    static func startTime(of pid: Int32) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_start_tvsec : 0
    }
}
