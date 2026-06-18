import Foundation

public struct InvocationBinding: Codable, Equatable, Sendable {
    public var peerIdentity: String
    public var injectorIdentity: String
    public var targetIdentity: String
    public var actionClass: String
    public var workspace: String
    public var originHint: String
    public var policyEpoch: Int
    public var injectionMode: DeliveryMode

    public init(peerIdentity: String, injectorIdentity: String, targetIdentity: String, actionClass: String, workspace: String, originHint: String, policyEpoch: Int, injectionMode: DeliveryMode) {
        self.peerIdentity = peerIdentity
        self.injectorIdentity = injectorIdentity
        self.targetIdentity = targetIdentity
        self.actionClass = actionClass
        self.workspace = workspace
        self.originHint = originHint
        self.policyEpoch = policyEpoch
        self.injectionMode = injectionMode
    }
}

public enum InvocationHandleError: Error, Equatable {
    case unknown
    case expired
    case replayed
    case wrongBinding
    case invalidTTL
}

public final class InvocationHandleStore: @unchecked Sendable {
    private struct Record {
        var binding: InvocationBinding
        var expiresAt: Date
        var remainingUses: Int
    }

    private var records: [String: Record] = [:]
    private let lock = NSLock()

    public init() {}

    public func create(binding: InvocationBinding, ttl: TimeInterval = 10, maxUses: Int = 1, now: Date = Date()) throws -> String {
        guard ttl > 0, ttl <= 30, maxUses > 0, maxUses <= 3 else {
            throw InvocationHandleError.invalidTTL
        }
        let handle = "ih_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        lock.withLock {
            records[handle] = Record(binding: binding, expiresAt: now.addingTimeInterval(ttl), remainingUses: maxUses)
        }
        return handle
    }

    public func consume(_ handle: String, expectedBinding: InvocationBinding, now: Date = Date()) throws {
        try lock.withLock {
            guard var record = records[handle] else {
                throw InvocationHandleError.unknown
            }
            guard record.remainingUses > 0 else {
                records.removeValue(forKey: handle)
                throw InvocationHandleError.replayed
            }
            guard record.expiresAt >= now else {
                records.removeValue(forKey: handle)
                throw InvocationHandleError.expired
            }
            guard record.binding == expectedBinding else {
                throw InvocationHandleError.wrongBinding
            }
            record.remainingUses -= 1
            if record.remainingUses == 0 {
                records.removeValue(forKey: handle)
            } else {
                records[handle] = record
            }
        }
    }
}

