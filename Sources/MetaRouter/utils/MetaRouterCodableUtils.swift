//
//  MetaRouterCodableUtils.swift
//  MetaRouter
//
//  Created by Christopher Houdlette on 8/4/25.
//


public enum MetaRouterCodableUtils {
    public static func toCodableValueDict(_ input: [String: Any]) -> [String: CodableValue] {
        var result: [String: CodableValue] = [:]
        for (key, value) in input {
            if let converted = CodableValue.from(value: value) {
                result[key] = converted
            }
        }
        return result
    }
}
