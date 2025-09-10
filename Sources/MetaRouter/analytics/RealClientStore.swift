//
//  RealClientStore.swift
//  MetaRouter
//
//  Created by Christopher Houdlette on 9/5/25.
//

import Foundation

actor RealClientStore {
    private var client: (any AnalyticsInterface)?

    func get() -> (any AnalyticsInterface)? { client }

    /// Returns true if the set happened (client was previously nil)
    @discardableResult
    func setIfNil(_ c: any AnalyticsInterface) -> Bool {
        guard client == nil else { return false }
        client = c
        return true
    }

    func clear() { client = nil }
}
