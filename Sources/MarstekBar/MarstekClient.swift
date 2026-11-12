import Foundation

struct MarstekError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal blocking client for the Marstek Local Open API (JSON over UDP).
/// Not thread-safe: call it from a single serial queue.
final class MarstekClient {
    struct Reply {
        let result: [String: Any]
        let sender: String
    }

    private let port: UInt16 = 30000
    private var requestID = 0

    /// Sends one request to every host in `hosts` and returns the first matching reply.
    func request(_ method: String,
                 params: [String: Any],
                 hosts: [String],
                 timeout: TimeInterval = 4) throws -> Reply {
        requestID += 1
        let id = requestID
        let payload = try JSONSerialization.data(
            withJSONObject: ["id": id, "method": method, "params": params])

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw MarstekError(message: "Не вдалося відкрити сокет") }
        defer { close(fd) }

        var yes: Int32 = 1
        let optLen = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, optLen)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, optLen)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, optLen)
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        // Some firmware versions only answer requests coming from port 30000,
        // so try to use it as the source port; fall back to an ephemeral one.
        if let local = Self.address("0.0.0.0", port: port) {
            _ = withUnsafePointer(to: local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let capacity = buffer.count

        for _ in 0..<2 {
            var sent = false
            for host in hosts {
                guard let dest = Self.address(host, port: port) else { continue }
                let n = payload.withUnsafeBytes { raw in
                    withUnsafePointer(to: dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, raw.count, 0, $0, addrLen)
                        }
                    }
                }
                if n >= 0 { sent = true }
            }
            // Nothing left the machine: no network, or Local Network access is denied.
            guard sent else {
                throw MarstekError(message: "Немає доступу до локальної мережі. "
                    + "Перевірте з'єднання та дозвіл у Системних параметрах")
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var from = sockaddr_in()
                var fromLen = addrLen
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, capacity, 0, $0, &fromLen)
                    }
                }
                guard n > 0 else { continue }

                let data = Data(buffer[0..<n])
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == id else { continue }

                if let result = object["result"] as? [String: Any] {
                    return Reply(result: result, sender: Self.string(from: from))
                }
                if let error = object["error"] as? [String: Any] {
                    let text = error["message"] as? String ?? "помилка пристрою"
                    throw MarstekError(message: "\(method): \(text)")
                }
                // Anything else (e.g. our own broadcast echoed back) is ignored.
            }
        }
        throw MarstekError(message: "Батарея не відповідає")
    }

    /// Limited broadcast plus the directed broadcast address of every active IPv4 interface.
    static func broadcastAddresses() -> [String] {
        var result = ["255.255.255.255"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }

        var cursor = list
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_BROADCAST != 0,
               let dst = current.pointee.ifa_dstaddr,
               dst.pointee.sa_family == sa_family_t(AF_INET) {
                let sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let text = string(from: sin)
                if !text.isEmpty, !result.contains(text) { result.append(text) }
            }
            cursor = current.pointee.ifa_next
        }
        return result
    }

    private static func address(_ host: String, port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    private static func string(from addr: sockaddr_in) -> String {
        var inAddr = addr.sin_addr
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &inAddr, &chars, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: chars)
    }
}
