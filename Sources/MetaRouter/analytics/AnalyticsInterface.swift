import Foundation

public protocol AnalyticsInterface: Sendable {
    func track(event: String, properties: [String: CodableValue]?) async
    func identify(userId: String, traits: [String: CodableValue]?) async
    func group(groupId: String, traits: [String: CodableValue]?) async
    func screen(name: String, properties: [String: CodableValue]?) async
    func alias(newUserId: String) async
    func flush() async
    func cleanup() async
    func enableDebugLogging() async
    func getDebugInfo() async -> [String: CodableValue]
}


public enum CodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([CodableValue])
    case dictionary([String: CodableValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodableValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodableValue].self) {
            self = .dictionary(value)
        } else {
            throw DecodingError.typeMismatch(CodableValue.self, DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Unsupported JSON type in CodableValue"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case .string(let v): try container.encode(v)
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .bool(let v): try container.encode(v)
            case .array(let v): try container.encode(v)
            case .dictionary(let v): try container.encode(v)
            case .null: try container.encodeNil()
        }
    }
    
    public static func from(value: Any) -> CodableValue? {
        switch value {
        case let v as String: return .string(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as Bool: return .bool(v)
        case let v as [Any]:
            return .array(v.compactMap { from(value: $0) })
        case let v as [String: Any]:
            var dict: [String: CodableValue] = [:]
            for (k, v) in v {
                if let cv = from(value: v) {
                    dict[k] = cv
                }
            }
            return .dictionary(dict)
        case _ as NSNull: return .null
        default: return nil
        }
    }
    
}
