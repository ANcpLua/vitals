import Darwin
import Foundation
import os

/// The measuring side of placement: a paced HTTP upload of zeros to Cloudflare's
/// speed-test endpoint and an ICMP echo to 1.1.1.1 four times a second.
///
/// Upload counts only what the server acknowledged: bytes written minus what
/// still sits in the socket's send buffer (`SO_NWRITE`), so the rate follows the
/// radio and not the Mac's buffer. Plain HTTP over a hand-made IPv4 socket keeps
/// that buffer readable; the body is zeros. IPv4 only: phone hotspots often hand
/// out IPv6 that does not route, and a connect then hangs per address.
public final class PlacementProbe: @unchecked Sendable {
    public struct Reading: Sendable {
        /// Acknowledged upload bytes since the probe started.
        public let ackedBytes: Int64
        /// Last echo round trip in ms; nil when the last echo went unanswered.
        public let pingMs: Double?
        /// An echo went unanswered since the previous reading.
        public let lostPing: Bool
        public let uploading: Bool
        public let error: String?
    }

    public static let uploadHost = "speed.cloudflare.com"
    public static let pingHost = "1.1.1.1"
    private static let soNWrite: Int32 = 0x1024
    private static let bodyBytes = 4 * 1024 * 1024
    private static let chunk = 16 * 1024
    private static let pingInterval: TimeInterval = 0.25
    private static let pingTimeout: TimeInterval = 1.0

    private struct State {
        var running = true
        var uploading = false
        var limitMbit = 10.0
        var written: Int64 = 0
        var socket: Int32 = -1
        var pingMs: Double?
        var lostSinceRead = false
        var error: String?
        var threads = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Starts the echo loop and the (idle) upload loop. The upload itself only
    /// runs between `setUploading(true)` and `setUploading(false)` or `stop()`.
    public func start() {
        state.withLock { $0.threads = 2 }
        let ping = Thread { [self] in pingLoop() }
        ping.name = "vitals.placement.ping"
        ping.start()
        let upload = Thread { [self] in uploadLoop() }
        upload.name = "vitals.placement.upload"
        upload.start()
    }

    /// Ends both loops. A send or read that is waiting on the network is cut
    /// off by shutting the socket down, so both threads exit within a second.
    public func stop() {
        state.withLock {
            $0.running = false
            $0.uploading = false
            if $0.socket >= 0 { shutdown($0.socket, SHUT_RDWR) }
        }
    }

    /// True once both threads have exited and their sockets are closed.
    public var isFinished: Bool {
        state.withLock { $0.threads == 0 }
    }

    public func setUploading(_ on: Bool) {
        state.withLock {
            $0.uploading = on
            if on { $0.error = nil }
            if !on, $0.socket >= 0 { shutdown($0.socket, SHUT_RDWR) }
        }
    }

    public func setLimit(mbit: Double) {
        state.withLock { $0.limitMbit = max(1, mbit) }
    }

    public func read() -> Reading {
        state.withLock { s in
            let pending = s.socket >= 0 ? Self.unacked(s.socket) : 0
            let reading = Reading(
                ackedBytes: s.written - Int64(pending),
                pingMs: s.pingMs,
                lostPing: s.lostSinceRead,
                uploading: s.uploading,
                error: s.uploading ? s.error : nil
            )
            s.lostSinceRead = false
            return reading
        }
    }

    private static func unacked(_ fd: Int32) -> Int {
        var value: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, soNWrite, &value, &size) == 0 ? Int(value) : 0
    }

    // MARK: Upload

    private func uploadLoop() {
        defer { state.withLock { $0.threads -= 1 } }
        while state.withLock({ $0.running }) {
            guard state.withLock({ $0.uploading }) else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            do {
                try uploadSession()
            } catch {
                // An error from cutting the socket on Stop is not a failure.
                guard state.withLock({ $0.running && $0.uploading }) else { continue }
                state.withLock { $0.error = "\(error)" }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
    }

    /// One keep-alive connection: POSTs of `bodyBytes` zeros, paced by a token
    /// bucket, until the upload is switched off or the connection fails.
    private func uploadSession() throws {
        let fd = try Self.connectIPv4(host: Self.uploadHost, port: 80)
        state.withLock { $0.socket = fd }
        defer {
            state.withLock { s in
                s.written -= Int64(Self.unacked(fd))
                s.socket = -1
            }
            close(fd)
        }
        let zeros = [UInt8](repeating: 0, count: Self.chunk)
        let header = Array((
            "POST /__up HTTP/1.1\r\nHost: \(Self.uploadHost)\r\nUser-Agent: vitals-placement\r\n"
                + "Content-Type: application/octet-stream\r\nContent-Length: \(Self.bodyBytes)\r\n\r\n"
        ).utf8)
        var tokens = 0.0
        var last = Date.timeIntervalSinceReferenceDate
        while true {
            try Self.sendAll(fd, header, count: header.count)
            var left = Self.bodyBytes
            while left > 0 {
                let (go, limit) = state.withLock { ($0.running && $0.uploading, $0.limitMbit) }
                guard go else { return }
                let rate = limit * 125_000
                let now = Date.timeIntervalSinceReferenceDate
                tokens = min(tokens + (now - last) * rate, rate * 0.25)
                last = now
                let n = min(Self.chunk, left)
                if tokens < Double(n) {
                    Thread.sleep(forTimeInterval: (Double(n) - tokens) / rate)
                    continue
                }
                try Self.sendAll(fd, zeros, count: n)
                tokens -= Double(n)
                left -= n
                state.withLock { $0.written += Int64(n) }
            }
            try Self.readResponse(fd)
            state.withLock { $0.error = nil }
        }
    }

    private static func connectIPv4(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw ProbeError(description: "no IPv4 address for \(host)")
        }
        defer { freeaddrinfo(list) }
        var lastError = "could not connect to \(host)"
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let info = entry {
            entry = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var connected = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
            if !connected, errno == EINPROGRESS {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&poller, 1, 4_000) == 1 {
                    var soError: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &size)
                    connected = soError == 0
                    if !connected { lastError = String(cString: strerror(soError)) }
                } else {
                    lastError = "connect to \(host) timed out"
                }
            }
            if connected {
                _ = fcntl(fd, F_SETFL, flags)
                return fd
            }
            close(fd)
        }
        throw ProbeError(description: lastError)
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8], count: Int) throws {
        var offset = 0
        while offset < count {
            let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + offset, count - offset, 0) }
            if sent < 0 {
                if errno == EINTR { continue }
                throw ProbeError(description: "upload: \(String(cString: strerror(errno)))")
            }
            offset += sent
        }
    }

    /// Reads one HTTP response: headers, then a Content-Length body if any.
    private static func readResponse(_ fd: Int32) throws {
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let separator: [UInt8] = [13, 10, 13, 10]
        var headerEnd: Int?
        while headerEnd == nil {
            let got = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard got > 0 else { throw ProbeError(description: "upload: connection closed by server") }
            data.append(contentsOf: buffer[0..<got])
            if data.count >= 4 {
                for i in 0...(data.count - 4) where Array(data[i..<(i + 4)]) == separator {
                    headerEnd = i + 4
                    break
                }
            }
            if data.count > 65_536 { throw ProbeError(description: "upload: oversized response") }
        }
        let head = String(decoding: data[0..<headerEnd!], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else {
            throw ProbeError(description: "upload: \(head.prefix(while: { $0 != "\r" }))")
        }
        var length = 0
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        var remaining = length - (data.count - headerEnd!)
        while remaining > 0 {
            let got = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, min($0.count, remaining), 0) }
            guard got > 0 else { throw ProbeError(description: "upload: connection closed by server") }
            remaining -= got
        }
    }

    // MARK: Ping

    /// ICMP echo through the unprivileged datagram socket macOS offers.
    private func pingLoop() {
        defer { state.withLock { $0.threads -= 1 } }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            state.withLock { $0.error = "ping: no ICMP socket" }
            return
        }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, Self.pingHost, &address.sin_addr)
        let ident = UInt16(truncatingIfNeeded: getpid())
        var sequence: UInt16 = 0
        var pending: [UInt16: TimeInterval] = [:]
        var nextSend = Date.timeIntervalSinceReferenceDate
        var buffer = [UInt8](repeating: 0, count: 2_048)

        while state.withLock({ $0.running }) {
            let now = Date.timeIntervalSinceReferenceDate
            if now >= nextSend {
                for (seq, sent) in pending where now - sent > Self.pingTimeout {
                    pending[seq] = nil
                    state.withLock {
                        $0.pingMs = nil
                        $0.lostSinceRead = true
                    }
                }
                let packet = Self.echoRequest(ident: ident, sequence: sequence)
                pending[sequence] = now
                _ = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sequence &+= 1
                nextSend = now + Self.pingInterval
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = max(1, Int32((nextSend - Date.timeIntervalSinceReferenceDate) * 1_000))
            guard poll(&poller, 1, wait) == 1 else { continue }
            let got = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            let received = Date.timeIntervalSinceReferenceDate
            guard got >= 8 else { continue }
            // The datagram socket hands back the IP header in front of the ICMP message.
            let offset = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0F) * 4 : 0
            guard got >= offset + 8, buffer[offset] == 0 else { continue }
            let replyIdent = UInt16(buffer[offset + 4]) << 8 | UInt16(buffer[offset + 5])
            let replySeq = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
            guard replyIdent == ident, let sent = pending.removeValue(forKey: replySeq) else { continue }
            state.withLock { $0.pingMs = (received - sent) * 1_000 }
        }
    }

    private static func echoRequest(ident: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0, UInt8(ident >> 8), UInt8(ident & 0xFF), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet += Array("vitals-placement".utf8)
        var sum: UInt32 = 0
        var i = 0
        while i < packet.count {
            let high = UInt32(packet[i]) << 8
            let low = i + 1 < packet.count ? UInt32(packet[i + 1]) : 0
            sum += high | low
            i += 2
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        let checksum = ~UInt16(sum)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xFF)
        return packet
    }
}
