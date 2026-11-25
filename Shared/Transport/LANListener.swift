#if os(macOS)
import Darwin
import dnssd
import Foundation

/// One inbound TCP connection at a time on an explicitly selected private
/// IPv4 interface. The session authenticates both peers after accepting a socket.
public final class LANListener: @unchecked Sendable {
    public static let serviceType = "_wireddisplay._tcp"
    public let port: UInt16

    public enum Failure: LocalizedError {
        case unavailableInterface(String)
        case addressChanged(String)
        case socket(String, Int32)
        case bonjour(DNSServiceErrorType)

        public var errorDescription: String? {
            switch self {
            case .unavailableInterface(let name): return "No private IPv4 address on \(name)"
            case .addressChanged(let name): return "The LAN address on \(name) changed"
            case .socket(let operation, let code): return "\(operation) failed (errno \(code))"
            case .bonjour(let code): return "Bonjour registration failed (\(code))"
            }
        }
    }

    private struct Interface: Equatable {
        let address: UInt32
        let mask: UInt32
    }

    private final class BonjourStatus: Sendable {
        let report: @Sendable (Result<String, Failure>) -> Void

        init(_ report: @escaping @Sendable (Result<String, Failure>) -> Void) {
            self.report = report
        }
    }

    private struct BonjourRegistration {
        let reference: DNSServiceRef
        let queue: DispatchQueue
        let status: BonjourStatus

        func close() {
            queue.sync {
                withExtendedLifetime(status) { DNSServiceRefDeallocate(reference) }
            }
        }
    }

    private let interfaceName: String
    private let boundInterface: Interface
    private let descriptor: Int32
    private let lock = NSLock()
    private var registration: BonjourRegistration?
    private var closed = false

    public init(interfaceName: String, serviceName: String, identityFingerprint: String? = nil,
                listeningPort: UInt16 = 0,
                registrationStatus: @escaping @Sendable (Result<String, Failure>) -> Void) throws {
        let index = if_nametoindex(interfaceName)
        guard index != 0, let interface = Self.privateInterface(interfaceName) else {
            throw Failure.unavailableInterface(interfaceName)
        }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw Failure.socket("socket", errno) }
        do {
            try Self.setNonblocking(fd)
            var reuse: Int32 = 1
            try Self.socketOption(fd, SOL_SOCKET, SO_REUSEADDR, &reuse)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = listeningPort.bigEndian
            address.sin_addr = in_addr(s_addr: interface.address.bigEndian)
            try Self.withAddress(&address) { pointer, size in
                guard Darwin.bind(fd, pointer, size) == 0 else { throw Failure.socket("bind", errno) }
            }
            guard Darwin.listen(fd, 4) == 0 else { throw Failure.socket("listen", errno) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            try withUnsafeMutablePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    guard getsockname(fd, $0, &length) == 0 else { throw Failure.socket("getsockname", errno) }
                }
            }

            port = UInt16(bigEndian: address.sin_port)
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.interfaceName = interfaceName
        boundInterface = interface
        descriptor = fd
        // A Mac already known to the iPad can still accept a paired connection
        // when Bonjour registration is unavailable.
        registration = Self.register(serviceName, index: index, port: port.bigEndian,
                                     fingerprint: identityFingerprint, status: BonjourStatus(registrationStatus))
    }

    deinit {
        close()
        Darwin.close(descriptor)
    }

    /// Call from a single accept loop. A returned descriptor belongs to the caller.
    public func accept(timeout: TimeInterval = 1) throws -> Int32? {
        guard !lock.withLock({ closed }) else { return nil }
        guard Self.privateInterface(interfaceName) == boundInterface else {
            throw Failure.addressChanged(interfaceName)
        }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = timeout.isFinite ? min(max(timeout * 1000, 0), 1000) : 1000
        let ready = poll(&pollDescriptor, 1, Int32(milliseconds))
        guard !lock.withLock({ closed }) else { return nil }
        if ready < 0, errno != EINTR { throw Failure.socket("poll", errno) }
        guard ready > 0 else { return nil }
        var source = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = withUnsafeMutablePointer(to: &source) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(descriptor, $0, &length)
            }
        }
        if fd < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ECONNABORTED { return nil }
            throw Failure.socket("accept", errno)
        }
        let address = UInt32(bigEndian: source.sin_addr.s_addr)
        guard !lock.withLock({ closed }), Self.isPrivate(address),
              address & boundInterface.mask == boundInterface.address & boundInterface.mask else {
            Darwin.close(fd)
            return nil
        }
        do {
            try Self.setNonblocking(fd)
            var enabled: Int32 = 1
            try Self.socketOption(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled)
            try Self.socketOption(fd, IPPROTO_TCP, TCP_NODELAY, &enabled)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func close() {
        let advertisement = lock.withLock {
            closed = true
            let ref = registration
            registration = nil
            return ref
        }
        advertisement?.close()
        shutdown(descriptor, SHUT_RDWR)
    }

    private static func register(_ serviceName: String, index: UInt32, port: UInt16, fingerprint: String?,
                                 status: BonjourStatus) -> BonjourRegistration? {
        // Discovery uses the public fingerprint only to identify candidates.
        // The handshake verifies the complete public key.
        let txt = NetService.data(fromTXTRecord: fingerprint.map { ["fp": Data($0.utf8)] } ?? [:])
        var reference: DNSServiceRef?
        let result = txt.withUnsafeBytes {
            DNSServiceRegister(&reference, 0, index, serviceName, serviceType, "local.", nil, port,
                               UInt16(txt.count), $0.baseAddress, { _, flags, error, name, _, _, context in
                guard let context else { return }
                let status = Unmanaged<BonjourStatus>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else {
                    status.report(.failure(.bonjour(error)))
                    return
                }
                guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let name else { return }
                status.report(.success(String(cString: name)))
            }, Unmanaged.passUnretained(status).toOpaque())
        }
        guard result == kDNSServiceErr_NoError, let reference else {
            status.report(.failure(.bonjour(result)))
            return nil
        }
        let queue = DispatchQueue(label: "wireddisplay.lan.bonjour")
        let queueResult = DNSServiceSetDispatchQueue(reference, queue)
        guard queueResult == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            status.report(.failure(.bonjour(queueResult)))
            return nil
        }
        return BonjourRegistration(reference: reference, queue: queue, status: status)
    }

    private static func privateInterface(_ name: String) -> Interface? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return nil }
        defer { freeifaddrs(list) }
        var next: UnsafeMutablePointer<ifaddrs>? = list
        while let entry = next?.pointee {
            next = entry.ifa_next
            guard String(cString: entry.ifa_name) == name,
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  let netmask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if isPrivate(ip), mask != 0 { return Interface(address: ip, mask: mask) }
        }
        return nil
    }

    private static func isPrivate(_ address: UInt32) -> Bool {
        switch address {
        case 0x0A00_0000...0x0AFF_FFFF, 0xAC10_0000...0xAC1F_FFFF, 0xC0A8_0000...0xC0A8_FFFF: true
        default: false
        }
    }

    private static func setNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.socket("fcntl", errno) }
    }

    private static func socketOption<T>(_ fd: Int32, _ level: Int32, _ option: Int32, _ value: inout T) throws {
        guard withUnsafePointer(to: &value, { setsockopt(fd, level, option, $0, socklen_t(MemoryLayout<T>.size)) }) == 0
        else { throw Failure.socket("setsockopt", errno) }
    }

    private static func withAddress(_ address: inout sockaddr_in,
                                    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
#endif
