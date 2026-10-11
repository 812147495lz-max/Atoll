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

enum ScreenAssistantTool: String {
    case captureScreen = "capture_screen"
    case captureCamera = "capture_camera"
    case listenMicrophone = "listen_microphone"
    case listenSystemAudio = "listen_system_audio"

    var description: String {
        switch self {
        case .captureScreen:
            return "Capture the user's current main display so you can visually inspect it."
        case .captureCamera:
            return "Take one photo with the Mac camera when visual context in front of the device is needed."
        case .listenMicrophone:
            return "Listen briefly to the microphone and return recognized speech as text."
        case .listenSystemAudio:
            return "Listen briefly to spoken system audio and return recognized speech as text."
        }
    }

    var statusText: String {
        switch self {
        case .captureScreen: return String(localized: "AI is looking at the screen…")
        case .captureCamera: return String(localized: "AI is taking a camera snapshot…")
        case .listenMicrophone: return String(localized: "AI is listening to the microphone…")
        case .listenSystemAudio: return String(localized: "AI is listening to system audio…")
        }
    }

    var resultLabel: String {
        switch self {
        case .captureScreen: return "A current screen image was captured and attached."
        case .captureCamera: return "A current camera image was captured and attached."
        case .listenMicrophone: return "Microphone speech transcription"
        case .listenSystemAudio: return "System audio speech transcription"
        }
    }
}

struct ScreenAssistantToolRequest {
    let tool: ScreenAssistantTool
    let duration: TimeInterval

    init?(name: String, arguments: Any?) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "capture_screen", "capture_full_screen", "take_screenshot":
            tool = .captureScreen
        case "capture_camera", "camera_snapshot", "take_camera_photo":
            tool = .captureCamera
        case "listen_microphone", "transcribe_microphone":
            tool = .listenMicrophone
        case "listen_system_audio", "transcribe_system_audio":
            tool = .listenSystemAudio
        default:
            return nil
        }

        let decodedArguments: [String: Any]
        if let dictionary = arguments as? [String: Any] {
            decodedArguments = dictionary
        } else if let string = arguments as? String,
                  let data = string.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            decodedArguments = dictionary
        } else {
            decodedArguments = [:]
        }

        let requestedDuration = (decodedArguments["duration_seconds"] as? NSNumber)?.doubleValue ?? 6
        duration = min(max(requestedDuration, 2), 15)
    }
}

struct ScreenAssistantToolExecutionResult {
    let summary: String
    let files: [ScreenAssistantFile]
}

enum ScreenAssistantToolCalling {
    static let maximumCallsPerUserMessage = 3

    static let systemPrompt = """
    You are the AI inside the Atoll macOS screen assistant. You can actively request device context when it is needed to answer the user's request. Available tools are capture_screen, capture_camera, listen_microphone, and listen_system_audio. Never claim you cannot see the desktop before requesting capture_screen. Never claim you cannot use the camera or hear speech before requesting the corresponding tool. Use a tool only when it is relevant to the user's current request. Microphone and system-audio tools accept duration_seconds from 2 through 15 and return speech transcription, not general sound classification.

    Prefer the API's native function/tool calling mechanism. If native tool calling is unavailable, request exactly one tool by replying with only this form:
    <atoll_tool>{"name":"capture_screen","arguments":{}}</atoll_tool>
    or:
    <atoll_tool>{"name":"listen_microphone","arguments":{"duration_seconds":6}}</atoll_tool>
    Do not wrap an Atoll tool request in Markdown. After Atoll returns the tool result, answer the user's original request using that result. macOS itself handles permission consent.
    """

    static var openAITools: [[String: Any]] {
        ScreenAssistantTool.allCasesForSchema.map { tool in
            [
                "type": "function",
                "function": functionDeclaration(for: tool, parametersKey: "parameters")
            ]
        }
    }

    static var anthropicTools: [[String: Any]] {
        ScreenAssistantTool.allCasesForSchema.map { tool in
            var declaration = functionDeclaration(for: tool, parametersKey: "input_schema")
            declaration.removeValue(forKey: "parameters")
            return declaration
        }
    }

    static var geminiFunctionDeclarations: [[String: Any]] {
        ScreenAssistantTool.allCasesForSchema.map { functionDeclaration(for: $0, parametersKey: "parameters") }
    }

    private static func functionDeclaration(
        for tool: ScreenAssistantTool,
        parametersKey: String
    ) -> [String: Any] {
        let properties: [String: Any]
        if tool == .listenMicrophone || tool == .listenSystemAudio {
            properties = [
                "duration_seconds": [
                    "type": "number",
                    "description": "How many seconds to listen, from 2 through 15.",
                    "minimum": 2,
                    "maximum": 15
                ]
            ]
        } else {
            properties = [:]
        }

        return [
            "name": tool.rawValue,
            "description": tool.description,
            parametersKey: [
                "type": "object",
                "properties": properties,
                "additionalProperties": false
            ]
        ]
    }

    static func parseResponse(
        data: Data,
        provider: AIModelProvider,
        customFormat: CustomAPIFormat
    ) -> (text: String?, tool: ScreenAssistantToolRequest?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let parsed: (String?, ScreenAssistantToolRequest?)
        switch provider {
        case .openai, .groq:
            parsed = parseOpenAI(json)
        case .claude:
            parsed = parseAnthropic(json)
        case .gemini:
            parsed = parseGemini(json)
        case .local:
            parsed = parseOllama(json)
        case .custom:
            switch customFormat {
            case .openAI: parsed = parseOpenAI(json)
            case .anthropic: parsed = parseAnthropic(json)
            case .gemini: parsed = parseGemini(json)
            case .ollama: parsed = parseOllama(json)
            }
        }

        if let tool = parsed.1 {
            return (parsed.0, tool)
        }
        if let text = parsed.0, let taggedTool = parseTaggedTool(from: text) {
            return (nil, taggedTool)
        }
        return (parsed.0, nil)
    }

    private static func parseOpenAI(_ json: [String: Any]) -> (String?, ScreenAssistantToolRequest?) {
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { return (nil, nil) }

        let text = message["content"] as? String
        if let call = (message["tool_calls"] as? [[String: Any]])?.first,
           let function = call["function"] as? [String: Any],
           let name = function["name"] as? String {
            return (text, ScreenAssistantToolRequest(name: name, arguments: function["arguments"]))
        }
        if let function = message["function_call"] as? [String: Any],
           let name = function["name"] as? String {
            return (text, ScreenAssistantToolRequest(name: name, arguments: function["arguments"]))
        }
        return (text, nil)
    }

    private static func parseAnthropic(_ json: [String: Any]) -> (String?, ScreenAssistantToolRequest?) {
        guard let blocks = json["content"] as? [[String: Any]] else { return (nil, nil) }
        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        if let block = blocks.first(where: { $0["type"] as? String == "tool_use" }),
           let name = block["name"] as? String {
            return (text.isEmpty ? nil : text, ScreenAssistantToolRequest(name: name, arguments: block["input"]))
        }
        return (text.isEmpty ? nil : text, nil)
    }

    private static func parseGemini(_ json: [String: Any]) -> (String?, ScreenAssistantToolRequest?) {
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return (nil, nil) }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if let call = parts.compactMap({ $0["functionCall"] as? [String: Any] }).first,
           let name = call["name"] as? String {
            return (text.isEmpty ? nil : text, ScreenAssistantToolRequest(name: name, arguments: call["args"]))
        }
        return (text.isEmpty ? nil : text, nil)
    }

    private static func parseOllama(_ json: [String: Any]) -> (String?, ScreenAssistantToolRequest?) {
        guard let message = json["message"] as? [String: Any] else { return (nil, nil) }
        let text = message["content"] as? String
        if let call = (message["tool_calls"] as? [[String: Any]])?.first,
           let function = call["function"] as? [String: Any],
           let name = function["name"] as? String {
            return (text, ScreenAssistantToolRequest(name: name, arguments: function["arguments"]))
        }
        return (text, nil)
    }

    private static func parseTaggedTool(from text: String) -> ScreenAssistantToolRequest? {
        guard let start = text.range(of: "<atoll_tool>"),
              let end = text.range(of: "</atoll_tool>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let payload = String(text[start.upperBound..<end.lowerBound])
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        return ScreenAssistantToolRequest(name: name, arguments: object["arguments"])
    }

    static func execute(_ request: ScreenAssistantToolRequest) async throws -> ScreenAssistantToolExecutionResult {
        switch request.tool {
        case .captureScreen:
            let url = try await ScreenshotSnippingTool.shared.captureFullScreen()
            return ScreenAssistantToolExecutionResult(
                summary: request.tool.resultLabel,
                files: [ScreenAssistantFile(fileURL: url)]
            )
        case .captureCamera:
            let url = try await ScreenAssistantMediaCaptureManager.shared.captureCameraPhoto()
            return ScreenAssistantToolExecutionResult(
                summary: request.tool.resultLabel,
                files: [ScreenAssistantFile(fileURL: url)]
            )
        case .listenMicrophone:
            let transcript = try await ScreenAssistantMediaCaptureManager.shared.transcribe(
                source: .microphone,
                duration: request.duration
            )
            return ScreenAssistantToolExecutionResult(
                summary: "\(request.tool.resultLabel): \(transcript)",
                files: []
            )
        case .listenSystemAudio:
            let transcript = try await ScreenAssistantMediaCaptureManager.shared.transcribe(
                source: .systemAudio,
                duration: request.duration
            )
            return ScreenAssistantToolExecutionResult(
                summary: "\(request.tool.resultLabel): \(transcript)",
                files: []
            )
        }
    }
}

private extension ScreenAssistantTool {
    static var allCasesForSchema: [ScreenAssistantTool] {
        [.captureScreen, .captureCamera, .listenMicrophone, .listenSystemAudio]
    }
}
