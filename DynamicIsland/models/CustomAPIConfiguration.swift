/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation
import Defaults

struct CustomAPIConfiguration {
    let name: String
    let format: CustomAPIFormat
    let endpoint: String
    let model: String
    let apiKey: String
    let authentication: CustomAPIAuthentication
    let authName: String
    let authPrefix: String
    let additionalHeaders: String

    static var current: CustomAPIConfiguration {
        CustomAPIConfiguration(
            name: Defaults[.customAPIName],
            format: Defaults[.customAPIFormat],
            endpoint: Defaults[.customAPIEndpoint],
            model: Defaults[.customAPIModel],
            apiKey: Defaults[.customAPIKey],
            authentication: Defaults[.customAPIAuthentication],
            authName: Defaults[.customAPIAuthName],
            authPrefix: Defaults[.customAPIAuthPrefix],
            additionalHeaders: Defaults[.customAPIAdditionalHeaders]
        )
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Custom API" : trimmedName
    }

    func resolvedURL() throws -> URL {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let expandedEndpoint = trimmedEndpoint.replacingOccurrences(of: "{model}", with: encodedModel)

        guard var components = URLComponents(string: expandedEndpoint),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw CustomAPIConfigurationError.invalidEndpoint
        }

        if authentication == .query {
            let parameterName = authName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !parameterName.isEmpty else {
                throw CustomAPIConfigurationError.missingAuthenticationName
            }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name.caseInsensitiveCompare(parameterName) == .orderedSame }
            queryItems.append(URLQueryItem(name: parameterName, value: apiKey))
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw CustomAPIConfigurationError.invalidEndpoint
        }
        return url
    }

    func requestHeaders() throws -> [String: String] {
        var headers = ["Content-Type": "application/json"]

        for line in additionalHeaders.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !["host", "content-length"].contains(name.lowercased()) else { continue }
            headers[name] = value
        }

        if format == .anthropic,
           !headers.keys.contains(where: { $0.caseInsensitiveCompare("anthropic-version") == .orderedSame }) {
            headers["anthropic-version"] = "2023-06-01"
        }

        switch authentication {
        case .bearer, .header:
            let headerName = authName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headerName.isEmpty else {
                throw CustomAPIConfigurationError.missingAuthenticationName
            }
            headers[headerName] = authPrefix + apiKey
        case .query, .none:
            break
        }

        return headers
    }
}

enum CustomAPIConfigurationError: LocalizedError {
    case invalidEndpoint
    case missingAuthenticationName

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Enter a valid HTTP or HTTPS API endpoint."
        case .missingAuthenticationName:
            return "Enter an authentication header or query parameter name."
        }
    }
}
