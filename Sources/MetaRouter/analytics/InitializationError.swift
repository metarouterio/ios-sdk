//
//  InitializationError.swift
//  MetaRouter
//
//  Created by Christopher Houdlette on 8/4/25.
//

import Foundation

public enum InitializationError: Error {
    case missingWriteKey
    case invalidIngestionHost
}

extension InitializationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingWriteKey:
            return "The writeKey is required and cannot be empty."
        case .invalidIngestionHost:
            return "The ingestionHost must be a valid URL (e.g., https://...)."
        }
    }
} 
