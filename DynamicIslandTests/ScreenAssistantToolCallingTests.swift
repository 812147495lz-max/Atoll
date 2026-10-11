/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import XCTest
@testable import Atoll

final class ScreenAssistantToolCallingTests: XCTestCase {
    func testParsesOpenAIToolCallAndClampsDuration() throws {
        let data = try jsonData([
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [[
                        "type": "function",
                        "function": [
                            "name": "listen_microphone",
                            "arguments": "{\"duration_seconds\":99}"
                        ]
                    ]]
                ]
            ]]
        ])

        let parsed = ScreenAssistantToolCalling.parseResponse(
            data: data,
            provider: .custom,
            customFormat: .openAI
        )

        XCTAssertEqual(parsed?.tool?.tool, .listenMicrophone)
        XCTAssertEqual(parsed?.tool?.duration, 15)
    }

    func testParsesAnthropicToolUse() throws {
        let data = try jsonData([
            "content": [[
                "type": "tool_use",
                "id": "tool_1",
                "name": "capture_camera",
                "input": [:]
            ]]
        ])

        let parsed = ScreenAssistantToolCalling.parseResponse(
            data: data,
            provider: .custom,
            customFormat: .anthropic
        )

        XCTAssertEqual(parsed?.tool?.tool, .captureCamera)
    }

    func testParsesGeminiFunctionCall() throws {
        let data = try jsonData([
            "candidates": [[
                "content": [
                    "parts": [[
                        "functionCall": [
                            "name": "capture_screen",
                            "args": [:]
                        ]
                    ]]
                ]
            ]]
        ])

        let parsed = ScreenAssistantToolCalling.parseResponse(
            data: data,
            provider: .gemini,
            customFormat: .gemini
        )

        XCTAssertEqual(parsed?.tool?.tool, .captureScreen)
    }

    func testParsesOllamaToolCall() throws {
        let data = try jsonData([
            "message": [
                "role": "assistant",
                "content": "",
                "tool_calls": [[
                    "function": [
                        "name": "listen_system_audio",
                        "arguments": ["duration_seconds": 4]
                    ]
                ]]
            ]
        ])

        let parsed = ScreenAssistantToolCalling.parseResponse(
            data: data,
            provider: .local,
            customFormat: .ollama
        )

        XCTAssertEqual(parsed?.tool?.tool, .listenSystemAudio)
        XCTAssertEqual(parsed?.tool?.duration, 4)
    }

    func testParsesTaggedFallbackFromTextOnlyAPI() throws {
        let data = try jsonData([
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "<atoll_tool>{\"name\":\"capture_screen\",\"arguments\":{}}</atoll_tool>"
                ]
            ]]
        ])

        let parsed = ScreenAssistantToolCalling.parseResponse(
            data: data,
            provider: .custom,
            customFormat: .openAI
        )

        XCTAssertEqual(parsed?.tool?.tool, .captureScreen)
        XCTAssertNil(parsed?.text)
    }

    func testReturnsOrdinaryAssistantText() throws {
        let data = try jsonData([
            "choices": [["message": ["content": "No device context is needed."]]]
        ])

        let parsed = ScreenAssistantToolCalling.parseResponse(
            data: data,
            provider: .openai,
            customFormat: .openAI
        )

        XCTAssertEqual(parsed?.text, "No device context is needed.")
        XCTAssertNil(parsed?.tool)
    }

    func testPublishesOnlyWhitelistedTools() {
        let names = ScreenAssistantToolCalling.openAITools.compactMap { item in
            (item["function"] as? [String: Any])?["name"] as? String
        }

        XCTAssertEqual(Set(names), Set([
            "capture_screen",
            "capture_camera",
            "listen_microphone",
            "listen_system_audio"
        ]))
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
