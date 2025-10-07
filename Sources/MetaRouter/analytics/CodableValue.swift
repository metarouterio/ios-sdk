//
//  CodableValue.swift
//  MetaRouter
//
//  Created by Christopher Houdlette on 9/5/25.
//

public enum CodableValue: Sendable, CustomStringConvertible {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case array([CodableValue])
  case object([String: CodableValue])
  case null
  
  public var description: String {
    return "\(toAny())"
  }
}

// MARK: - Codable Implementation

extension CodableValue: Codable {
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
  
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    
    if container.decodeNil() {
      self = .null
      return
    }
    
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    
    if let value = try? container.decode(Int.self) {
      self = .int(value)
      return
    }
    
    if let value = try? container.decode(Double.self) {
      self = .double(value)
      return
    }
    
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
      return
    }
    
    if let value = try? container.decode([CodableValue].self) {
      self = .array(value)
      return
    }
    
    if let value = try? container.decode([String: CodableValue].self) {
      self = .object(value)
      return
    }
    
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Cannot decode CodableValue"
    )
  }
}

extension CodableValue: ExpressibleByStringLiteral,
                        ExpressibleByIntegerLiteral,
                        ExpressibleByFloatLiteral,
                        ExpressibleByBooleanLiteral,
                        ExpressibleByArrayLiteral,
                        ExpressibleByDictionaryLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: CodableValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, CodableValue)...) {
    self = .object(.init(uniqueKeysWithValues: elements))
  }
}

extension CodableValue {
  /// Convert `Any` to `CodableValue` for common types
  /// Returns nil if the type is not supported
  public static func from(_ value: Any) -> CodableValue? {
    // Check for Optional<Any> first using Mirror
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
      if mirror.children.count == 0 {
        return .null
      } else if let (_, wrappedValue) = mirror.children.first {
        return CodableValue.from(wrappedValue)
      }
    }
    
    switch value {
    // If it's already a CodableValue, return it as-is
    case let codableValue as CodableValue:
      return codableValue
    case let string as String:
      return .string(string)
    case let int as Int:
      return .int(int)
    case let double as Double:
      return .double(double)
    case let float as Float:
      return .double(Double(float))
    case let bool as Bool:
      return .bool(bool)
    case let array as [Any]:
      let converted = array.compactMap { CodableValue.from($0) }
      // Only return array if all elements converted successfully
      guard converted.count == array.count else { return nil }
      return .array(converted)
    case let dict as [String: Any]:
      var converted: [String: CodableValue] = [:]
      for (key, val) in dict {
        guard let codableVal = CodableValue.from(val) else { return nil }
        converted[key] = codableVal
      }
      return .object(converted)
    default:
      return nil
    }
  }
  
  /// Convert `[String: Any]` to `[String: CodableValue]`
  /// Returns nil if any value cannot be converted
  public static func convert(_ dict: [String: Any]) -> [String: CodableValue]? {
    var result: [String: CodableValue] = [:]
    for (key, value) in dict {
      switch value {
      case let string as String:
        result[key] = .string(string)
      case let int as Int:
        result[key] = .int(int)
      case let double as Double:
        result[key] = .double(double)
      case let float as Float:
        result[key] = .double(Double(float))
      case let bool as Bool:
        result[key] = .bool(bool)
      case let array as [Any]:
        let converted = array.compactMap { CodableValue.from($0) }
        guard converted.count == array.count else { return nil }
        result[key] = .array(converted)
      case let dict as [String: Any]:
        guard let converted = CodableValue.convert(dict) else { return nil }
        result[key] = .object(converted)
      case Optional<Any>.none:
        result[key] = .null
      default:
        return nil
      }
    }
    return result
  }
  
  /// Convert CodableValue to simple Any representation for cleaner logging
  internal func toAny() -> Any {
    switch self {
    case .string(let value):
      return value
    case .int(let value):
      return value
    case .double(let value):
      return value
    case .bool(let value):
      return value
    case .array(let values):
      return values.map { $0.toAny() }
    case .object(let dict):
      return dict.mapValues { $0.toAny() }
    case .null:
      return "null"
    }
  }
}


extension Dictionary where Key == String, Value == CodableValue {
  /// Returns a clean string representation without CodableValue wrappers
  public var cleanDescription: String {
    let simplified = self.mapValues { $0.toAny() }
    return "\(simplified)"
  }
}
