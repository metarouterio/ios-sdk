//
//  AnalyticsClientStore.swift
//  MetaRouter
//
//  Created by Christopher Houdlette on 8/4/25.
//

public actor AnalyticsClientStore {
    private var clientInstance: AnalyticsClient?

    static let shared = AnalyticsClientStore()

    func get() -> AnalyticsClient? {
        return clientInstance
    }

    func set(_ client: AnalyticsClient) {
        clientInstance = client
    }

    func clear() {
        clientInstance = nil
    }
}
