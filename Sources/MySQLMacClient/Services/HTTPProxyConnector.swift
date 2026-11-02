import CryptoKit
import Darwin
import Foundation

/// Opens a TCP connection to `host:port` through an HTTP proxy with
/// `CONNECT`, answering the proxy's login challenge (407) with Digest when
/// it offers that — the password never goes over the network — or else
/// Basic.
enum HTTPProxyConnector {
    struct Proxy: Equatable, Sendable {
        var host: String
        var port: Int
        var username: String
        var password: String
    }

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        /// The proxy turned down the login it was sent: asking again would
        /// only send it again.
        var loginRefused = false
        var errorDescription: String? { message }
    }

    /// How long the proxy gets to answer, as a direct connection would.
    private static let answerTimeout = 15

    /// A connected socket to `host:port`, with the proxy's answer already
    /// read off it, so whatever comes next is the server's.
    static func connect(through proxy: Proxy, to host: String, port: Int) throws -> Int32 {
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        var authorization: String?
        // No login at first: the proxy's 407 says how it wants one, and a
        // new connection gives it. Digest once more when its nonce was stale.
        for attempt in 0..<3 {
            let fd = try connectTCP(proxy.host, proxy.port)
            var head = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
            if let authorization { head += "Proxy-Authorization: \(authorization)\r\n" }
            guard Array((head + "\r\n").utf8).withUnsafeBytes({ writeAll(fd, $0) }) else {
                close(fd)
                throw Failure(message: String(localized: "The proxy closed the connection."))
            }
            let answer: (head: [UInt8], bodyStart: Int)
            do {
                answer = try readHead(fd)
            } catch {
                close(fd)
                throw error
            }
            let headText = String(decoding: answer.head.prefix(answer.bodyStart), as: UTF8.self)
            // "\r\n" is one Character, neither "\r" nor "\n".
            let statusLine = String(headText.prefix { !$0.isNewline })
            let code = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            if (200..<300).contains(code), statusLine.hasPrefix("HTTP/") {
                // A CONNECT answer has no body: anything past its empty line
                // would already be the server's, and ssh speaks first, so
                // there is none.
                return fd
            }
            close(fd)
            let offered = challenges(in: headText)
            // tinyproxy turns a login down with 401, others with 407 again.
            let loginRefused = authorization != nil && (code == 401 || code == 407)
            guard code == 407, !proxy.username.isEmpty, attempt < 2 else {
                throw Failure(message: String(localized: "The proxy refused the connection to \(target): \(statusLine)"),
                              loginRefused: loginRefused)
            }
            let sentDigest = authorization?.hasPrefix("Digest ") == true
            if let digest = offered.first(where: { $0.scheme == "digest" })?.parameters,
               authorization == nil || sentDigest && digest["stale"]?.lowercased() == "true",
               let answerHeader = Self.digest(digest, username: proxy.username, password: proxy.password, uri: target, cnonce: cnonce()) {
                authorization = answerHeader
            } else if authorization == nil, offered.isEmpty || offered.contains(where: { $0.scheme == "basic" }) {
                authorization = "Basic " + Data("\(proxy.username):\(proxy.password)".utf8).base64EncodedString()
            } else {
                throw Failure(message: String(localized: "The proxy refused the connection to \(target): \(statusLine)"),
                              loginRefused: loginRefused)
            }
        }
        throw Failure(message: String(localized: "The proxy refused the connection to \(target)."))
    }

    /// The proxy's answer up to its empty line.
    private static func readHead(_ fd: Int32) throws -> (head: [UInt8], bodyStart: Int) {
        var limit = timeval(tv_sec: answerTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        defer {
            var none = timeval(tv_sec: 0, tv_usec: 0)  // a quiet tunnel is no reason to end it
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        }
        var answer = [UInt8]()
        var byte: UInt8 = 0
        // One byte at a time, so nothing past the empty line is taken from
        // what belongs to the tunnel.
        while true {
            let count = read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                throw Failure(message: String(localized: "The proxy didn't answer within \(answerTimeout) seconds."))
            }
            guard count > 0 else { throw Failure(message: String(localized: "The proxy closed the connection.")) }
            answer.append(byte)
            if answer.count >= 4, answer.suffix(4).elementsEqual([13, 10, 13, 10]) {
                return (answer, answer.count)
            }
            if answer.count > 65536 { throw Failure(message: String(localized: "The proxy's answer is too long.")) }
        }
    }

    /// The Proxy-Authenticate challenges in a response head: each scheme
    /// (lowercased) with its parameters.
    static func challenges(in head: String) -> [(scheme: String, parameters: [String: String])] {
        head.components(separatedBy: "\r\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "proxy-authenticate" else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let scheme = String(value.prefix { !$0.isWhitespace })
            var parameters: [String: String] = [:]
            var rest = Substring(value.dropFirst(scheme.count))
            // name=value or name="quoted, value", separated by commas.
            while let equals = rest.firstIndex(of: "=") {
                let name = rest[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " ,")).lowercased()
                rest = rest[rest.index(after: equals)...].drop { $0 == " " }
                var parsed = ""
                if rest.first == "\"" {
                    rest = rest.dropFirst()
                    while let character = rest.first, character != "\"" {
                        if character == "\\" { rest = rest.dropFirst() }
                        if let next = rest.first { parsed.append(next) }
                        rest = rest.dropFirst()
                    }
                    rest = rest.dropFirst()
                } else {
                    parsed = String(rest.prefix { $0 != "," }).trimmingCharacters(in: .whitespaces)
                    rest = rest.dropFirst(parsed.count)
                }
                parameters[name] = parsed
            }
            return (scheme.lowercased(), parameters)
        }
    }

    /// The Proxy-Authorization value answering a Digest challenge (RFC 7616:
    /// MD5 or SHA-256, their -sess forms, qop auth or none) for CONNECT to
    /// `uri`; nil for an algorithm or qop it can't answer.
    static func digest(_ challenge: [String: String], username: String, password: String, uri: String, cnonce: String,
                       method: String = "CONNECT") -> String? {
        guard let realm = challenge["realm"], let nonce = challenge["nonce"] else { return nil }
        let algorithm = challenge["algorithm"] ?? "MD5"
        let hash: (String) -> String
        switch algorithm.uppercased().replacingOccurrences(of: "-SESS", with: "") {
        case "MD5": hash = { Insecure.MD5.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        case "SHA-256": hash = { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        default: return nil
        }
        let qops = (challenge["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard qops.isEmpty || qops.contains("auth") else { return nil }
        let nc = "00000001"
        var a1 = hash("\(username):\(realm):\(password)")
        if algorithm.uppercased().hasSuffix("-SESS") { a1 = hash("\(a1):\(nonce):\(cnonce)") }
        let a2 = hash("\(method):\(uri)")
        let response = qops.isEmpty ? hash("\(a1):\(nonce):\(a2)") : hash("\(a1):\(nonce):\(nc):\(cnonce):auth:\(a2)")
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var parts = ["username=\(quoted(username))", "realm=\(quoted(realm))", "nonce=\(quoted(nonce))", "uri=\(quoted(uri))",
                     "algorithm=\(algorithm)", "response=\(quoted(response))"]
        if !qops.isEmpty { parts += ["qop=auth", "nc=\(nc)", "cnonce=\(quoted(cnonce))"] }
        if let opaque = challenge["opaque"] { parts.append("opaque=\(quoted(opaque))") }
        return "Digest " + parts.joined(separator: ", ")
    }

    /// A fresh client nonce: 16 random bytes, hex.
    private static func cnonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// A TCP connection to host:port, trying each of its addresses in turn.
    private static func connectTCP(_ host: String, _ port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0 else {
            throw Failure(message: String(localized: "Can't find the proxy \(host): \(String(cString: gai_strerror(status)))"))
        }
        defer { freeaddrinfo(list) }
        var error = ECONNREFUSED
        var next = list
        while let info = next?.pointee {
            next = info.ai_next
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else {
                error = errno
                continue
            }
            var seconds: Int32 = 15
            setsockopt(fd, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &seconds, socklen_t(MemoryLayout<Int32>.size))
            if Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0 {
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            error = errno
            close(fd)
        }
        // String(port): an Int would be shown with digit grouping (3,128).
        throw Failure(message: String(localized: "Can't connect to the proxy \(host):\(String(port)): \(String(cString: strerror(error)))"))
    }

    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}
