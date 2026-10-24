import Darwin
import Foundation

public struct ResolvedAddress: Equatable, Sendable {
    public let family: Int32
    public let sockaddr: Data
    public let display: String
}

public enum PingError: Error, Equatable, Sendable {
    case resolution(String)
    case socket(String)

    public var message: String {
        switch self {
        case .resolution(let detail): "Could not resolve host: \(detail)"
        case .socket(let detail): "Could not open ICMP socket: \(detail)"
        }
    }
}

/// Sends ICMP echo requests over an unprivileged datagram socket, like Apple's SimplePing.
///
/// All the host's addresses are kept: when a send fails or the current address stops answering,
/// the next one is tried (see AddressSelector).
@MainActor
public final class Pinger {
    public enum Event: Sendable {
        case started(ResolvedAddress)
        /// Pings now go to another of the host's addresses.
        case switched(ResolvedAddress)
        case failed(PingError)
        /// `at` is a MonotonicClock timestamp.
        case reply(id: UInt64, at: TimeInterval)
    }

    private struct Socket {
        let fd: Int32
        let source: DispatchSourceRead
    }

    public let hostName: String
    /// ICMP identifier echoed back in replies; replies carrying another identifier belong to someone else.
    public let identifier: UInt16
    public var onEvent: ((Event) -> Void)?
    public private(set) var addresses: [ResolvedAddress] = []

    private var selector = AddressSelector(count: 0)
    /// Which address each recent ping went to, so a reply is credited to the right one.
    private var sentTo: [UInt64: Int] = [:]
    private let responseDeadline: TimeInterval
    private var sockets: [Int32: Socket] = [:]
    private var generation = 0

    /// Tags our echo payloads so replies to other processes' pings are ignored.
    nonisolated static let magic = Array("FIVEBARS".utf8)

    /// `responseDeadline`: how long an address may leave a ping unanswered before the next one is tried.
    public init(hostName: String, identifier: UInt16 = .random(in: .min ... .max), responseDeadline: TimeInterval = 4) {
        self.hostName = hostName
        self.identifier = identifier
        self.responseDeadline = responseDeadline
    }

    public var isRunning: Bool { !sockets.isEmpty }

    public var address: ResolvedAddress? {
        addresses.indices.contains(selector.index) ? addresses[selector.index] : nil
    }

    public func start() {
        stop()
        generation += 1
        let startedGeneration = generation
        let host = hostName
        Task {
            let result = await Task.detached(priority: .utility) { Pinger.resolve(host) }.value
            guard startedGeneration == generation else { return }
            switch result {
            case .success(let resolved):
                open(resolved)
            case .failure(let error):
                onEvent?(.failed(error))
            }
        }
    }

    public func stop() {
        generation += 1
        for socket in sockets.values {
            socket.source.cancel()
        }
        sockets.removeAll()
        addresses.removeAll()
        selector = AddressSelector(count: 0)
        sentTo.removeAll()
    }

    @discardableResult
    public func send(id: UInt64) -> Bool {
        guard let address, let socket = sockets[address.family] else { return false }
        let packet = Pinger.echoRequest(id: id, identifier: identifier, family: address.family)
        let sent = address.sockaddr.withUnsafeBytes { addr in
            packet.withUnsafeBytes { bytes in
                sendto(
                    socket.fd,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    addr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                    socklen_t(addr.count)
                )
            }
        }
        let ok = sent == packet.count
        sentTo[id] = selector.index
        if sentTo.count > 64, let oldest = sentTo.keys.min() {
            sentTo[oldest] = nil
        }
        if ok ? selector.sent(at: MonotonicClock.now()) : selector.sendFailed(), let next = self.address {
            onEvent?(.switched(next))
        }
        return ok
    }

    private func open(_ resolved: [ResolvedAddress]) {
        var lastError = "no usable address"
        for family in Set(resolved.map(\.family)) {
            let proto = family == AF_INET ? IPPROTO_ICMP : IPPROTO_ICMPV6
            let fd = socket(family, SOCK_DGRAM, proto)
            guard fd >= 0 else {
                lastError = String(cString: strerror(errno))
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.readAvailable(fd: fd, family: family)
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            sockets[family] = Socket(fd: fd, source: source)
            source.resume()
        }
        // Only keep addresses whose family has a socket.
        addresses = resolved.filter { sockets[$0.family] != nil }
        selector = AddressSelector(count: addresses.count, deadline: responseDeadline)
        guard let first = addresses.first else {
            onEvent?(.failed(.socket(lastError)))
            return
        }
        onEvent?(.started(first))
    }

    private func readAvailable(fd: Int32, family: Int32) {
        guard sockets[family]?.fd == fd else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { break }
            let now = MonotonicClock.now()
            if let id = Pinger.parseReply(Array(buffer[0..<count]), family: family, identifier: identifier) {
                if let answered = sentTo.removeValue(forKey: id), selector.replied(from: answered), let back = address {
                    onEvent?(.switched(back))
                }
                onEvent?(.reply(id: id, at: now))
            }
        }
    }

    // MARK: - Packet handling

    /// Resolves every IPv4 and IPv6 address of `host`, in the resolver's preferred order, without duplicates.
    nonisolated static func resolve(_ host: String) -> Result<[ResolvedAddress], PingError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        guard status == 0, let list else {
            return .failure(.resolution(String(cString: gai_strerror(status))))
        }
        defer { freeaddrinfo(list) }

        var addresses: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let info = cursor?.pointee {
            if info.ai_family == AF_INET || info.ai_family == AF_INET6, let addr = info.ai_addr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, info.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let address = ResolvedAddress(
                    family: info.ai_family,
                    sockaddr: Data(bytes: addr, count: Int(info.ai_addrlen)),
                    display: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                )
                if !addresses.contains(address) {
                    addresses.append(address)
                }
            }
            cursor = info.ai_next
        }
        return addresses.isEmpty ? .failure(.resolution("no IPv4 or IPv6 address")) : .success(addresses)
    }

    nonisolated static func echoRequest(id: UInt64, identifier: UInt16, family: Int32) -> [UInt8] {
        let sequence = UInt16(truncatingIfNeeded: id)
        var packet: [UInt8] = [
            family == AF_INET ? 8 : 128, 0, 0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xff),
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
        ]
        packet += magic
        withUnsafeBytes(of: id.bigEndian) { packet += $0 }
        // The kernel fills in the ICMPv6 checksum; ICMPv4 is ours to compute.
        if family == AF_INET {
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xff)
        }
        return packet
    }

    nonisolated static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(sum)
    }

    /// Returns the ping id carried by one of our echo replies, or nil for anything else.
    nonisolated static func parseReply(_ packet: [UInt8], family: Int32, identifier: UInt16) -> UInt64? {
        var offset = 0
        // IPv4 datagram ICMP sockets deliver the IP header too.
        if family == AF_INET, let first = packet.first, first >> 4 == 4 {
            offset = Int(first & 0x0f) * 4
        }
        let payload = offset + 8
        guard packet.count >= payload + magic.count + 8 else { return nil }
        guard packet[offset] == (family == AF_INET ? 0 : 129), packet[offset + 1] == 0 else { return nil }
        guard Array(packet[payload..<payload + magic.count]) == magic else { return nil }
        // Every ICMP socket on the machine sees every echo reply: only take the ones sent with our identifier.
        guard UInt16(packet[offset + 4]) << 8 | UInt16(packet[offset + 5]) == identifier else { return nil }

        var id: UInt64 = 0
        for byte in packet[payload + magic.count..<payload + magic.count + 8] {
            id = id << 8 | UInt64(byte)
        }
        let sequence = UInt16(packet[offset + 6]) << 8 | UInt16(packet[offset + 7])
        return sequence == UInt16(truncatingIfNeeded: id) ? id : nil
    }
}
