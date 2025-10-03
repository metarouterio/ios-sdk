//
//  CodableValue.swift
//  MetaRouter
//
//  Created by Christopher Houdlette on 9/5/25.
//

public enum CodableValue: Codable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case array([CodableValue])
  case object([String: CodableValue])
  case null
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


/// Protocol for types that can be converted to CodableValue
public protocol CodableValueConvertible {
  var codableValue: CodableValue { get }
}

extension String: CodableValueConvertible {
  public var codableValue: CodableValue { .string(self) }
}

extension Int: CodableValueConvertible {
  public var codableValue: CodableValue { .int(self) }
}

extension Double: CodableValueConvertible {
  public var codableValue: CodableValue { .double(self) }
}

extension Float: CodableValueConvertible {
  public var codableValue: CodableValue { .double(Double(self)) }
}

extension Bool: CodableValueConvertible {
  public var codableValue: CodableValue { .bool(self) }
}

extension Array: CodableValueConvertible where Element: CodableValueConvertible {
  public var codableValue: CodableValue { .array(map { $0.codableValue }) }
}

extension Dictionary: CodableValueConvertible where Key == String, Value: CodableValueConvertible {
  public var codableValue: CodableValue { .object(mapValues { $0.codableValue }) }
}

extension Optional: CodableValueConvertible where Wrapped: CodableValueConvertible {
  public var codableValue: CodableValue {
    switch self {
    case .some(let value): return value.codableValue
    case .none: return .null
    }
  }
}
