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

    /// Sets the client unconditionally, replacing any existing client
    func set(_ c: any AnalyticsInterface) {
        client = c
    }

    func clear() { client = nil }
}
