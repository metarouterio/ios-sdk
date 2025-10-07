//
//  CodableValue.swift
//  MetaRouter
//
//  Created by Christopher Houdlette on 9/5/25.
//

import Foundation

/// A type-safe wrapper for JSON-compatible values that supports encoding/decoding
/// and provides convenient conversion between Swift types.
///
/// CodableValue provides a safe way to handle arbitrary JSON data while maintaining
/// type safety and easy conversion between Swift types. It supports all JSON-compatible
/// types and provides convenient literal syntax for creating values.
///
/// Example usage:
/// ```swift
/// // Create from literals
/// let value: CodableValue = ["name": "John", "age": 30]
///
/// // Convert from Any
/// let dict: [String: Any] = ["score": 42, "valid": true]
/// if let converted = CodableValue.from(dict) {
///   print(converted.objectValue?["score"]?.intValue) // Optional(42)
/// }
///
/// // Encode/decode
/// let data = try JSONEncoder().encode(value)
/// let decoded = try JSONDecoder().decode(CodableValue.self, from: data)
/// ```
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
  
  
  /// The string value if this is a .string case, nil otherwise
  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
  
  /// The integer value if this is an .int case, nil otherwise
  public var intValue: Int? {
    guard case .int(let value) = self else { return nil }
    return value
  }
  
  /// The double value if this is a .double case or an .int case that can be converted, nil otherwise
  public var doubleValue: Double? {
    switch self {
    case .double(let value): return value
    case .int(let value): return Double(value)
    default: return nil
    }
  }
  
  /// The boolean value if this is a .bool case, nil otherwise
  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
  
  /// The array value if this is an .array case, nil otherwise
  public var arrayValue: [CodableValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }
  
  /// The dictionary value if this is an .object case, nil otherwise
  public var objectValue: [String: CodableValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }
  
  /// Whether this value is .null
  public var isNull: Bool {
    guard case .null = self else { return false }
    return true
  }
}


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

private extension Mirror {
  func unwrapOptional() -> Any? {
    guard displayStyle == .optional else { return nil }
    guard let (_, value) = children.first else { return nil }
    return value
  }
}

extension CodableValue {
  /// Convert any supported value to CodableValue
  /// - Parameter value: The value to convert
  /// - Returns: A CodableValue if the conversion was successful, nil otherwise
  public static func from(_ value: Any) -> CodableValue? {
    // Handle Optional<Any> first
    if let unwrapped = Mirror(reflecting: value).unwrapOptional() {
      return from(unwrapped)
    }
    
    // Handle already converted values
    if let codableValue = value as? CodableValue {
      return codableValue
    }
    
    // Handle primitive types
    switch value {
    case let string as String: return .string(string)
    case let int as Int: return .int(int)
    case let double as Double: return .double(double)
    case let float as Float: return .double(Double(float))
    case let bool as Bool: return .bool(bool)
    case let array as [Any]:
      let converted = array.compactMap(from)
      return converted.count == array.count ? .array(converted) : nil
    case let dict as [String: Any]:
      var converted: [String: CodableValue] = [:]
      converted.reserveCapacity(dict.count) // Performance optimization
      for (key, val) in dict {
        guard let codableVal = from(val) else { return nil }
        converted[key] = codableVal
      }
      return .object(converted)
    case Optional<Any>.none: return .null
    default: return nil
    }
  }
  
  /// Convenience method for converting dictionaries
  /// - Parameter dict: The dictionary to convert
  /// - Returns: A dictionary with CodableValue values if the conversion was successful, nil otherwise
  public static func convert(_ dict: [String: Any]) -> [String: CodableValue]? {
    guard case .object(let converted)? = from(dict) else { return nil }
    return converted
  }
  
  /// Convert CodableValue to simple Any representation for cleaner logging
  internal func toAny() -> Any {
    switch self {
    case .string(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .bool(let value): return value
    case .array(let values): return values.map { $0.toAny() }
    case .object(let dict): return dict.mapValues { $0.toAny() }
    case .null: return "null"
    }
  }
  
  /// Convert to Dictionary with type-safe values
  public func toDictionary() -> [String: Any]? {
    guard case .object(let dict) = self else { return nil }
    return dict.mapValues { $0.toTypedValue() }
  }
  
  /// Convert to Array with type-safe values
  public func toArray() -> [Any]? {
    guard case .array(let array) = self else { return nil }
    return array.map { $0.toTypedValue() }
  }
  
  /// Convert to a type-safe value
  private func toTypedValue() -> Any {
    switch self {
    case .string(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .bool(let value): return value
    case .array(let values): return values.map { $0.toTypedValue() }
    case .object(let dict): return dict.mapValues { $0.toTypedValue() }
    case .null: return NSNull()
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
