import CryptoKit
import Foundation

public enum AgenticSecretsJSON {
    public static func encodePretty<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

public func stableDigest(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

public func shortDigest(_ input: String, length: Int = 12) -> String {
    String(stableDigest(input).prefix(length))
}

public struct Clock: Sendable {
    private let nowClosure: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.nowClosure = now
    }

    public func now() -> Date {
        nowClosure()
    }
}

extension NSLock {
    package func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

