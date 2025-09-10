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
