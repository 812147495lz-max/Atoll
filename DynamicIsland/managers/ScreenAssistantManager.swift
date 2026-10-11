/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import SwiftUI
import AVFoundation
import Defaults
import Foundation

// Chat message model
struct ChatMessage: Identifiable, Codable {
    let id = UUID()
    let content: String
    let isFromUser: Bool
    let timestamp: Date
    let attachedFiles: [ScreenAssistantFile]?
    
    init(content: String, isFromUser: Bool, attachedFiles: [ScreenAssistantFile]? = nil) {
        self.content = content
        self.isFromUser = isFromUser
        self.timestamp = Date()
        self.attachedFiles = attachedFiles
    }
}

// Screen Assistant item data structure
struct ScreenAssistantFile: Identifiable, Codable {
    let id = UUID()
    let name: String
    let type: FileType
    let timestamp: Date
    let fileURL: String? // For local files
    let audioFileName: String? // For audio recordings
    
    enum FileType: String, CaseIterable, Codable {
        case document = "document"
        case image = "image"
        case audio = "audio"
        case video = "video"
        case other = "other"
        
        var iconName: String {
            switch self {
            case .document: return "doc.text"
            case .image: return "photo"
            case .audio: return "waveform"
            case .video: return "video"
            case .other: return "doc"
            }
        }
        
        var displayName: String {
            switch self {
            case .document: return String(localized: "Document")
            case .image: return String(localized: "Image")
            case .audio: return String(localized: "Audio")
            case .video: return String(localized: "Video")
            case .other: return String(localized: "File")
            }
        }
    }
    
    init(fileURL: URL) {
        // Defensive initialization with nil coalescing
        self.name = fileURL.lastPathComponent.isEmpty ? "Unknown File" : fileURL.lastPathComponent
        self.fileURL = fileURL.absoluteString
        self.audioFileName = nil
        self.timestamp = Date()
        
        // Safe file extension extraction
        let fileExtension = fileURL.pathExtension.lowercased()
        switch fileExtension {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic":
            self.type = .image
        case "mp3", "wav", "m4a", "aac", "flac":
            self.type = .audio
        case "mp4", "mov", "avi", "mkv":
            self.type = .video
        case "txt", "md", "pdf", "doc", "docx", "rtf":
            self.type = .document
        default:
            self.type = .other
        }
        
        print("✅ ScreenAssistantFile: Created file entry - name: \(self.name), type: \(self.type), url: \(self.fileURL ?? "nil")")
    }
    
    init(audioFileName: String, name: String) {
        self.name = name
        self.type = .audio
        self.fileURL = nil
        self.audioFileName = audioFileName
        self.timestamp = Date()
    }
}

class ScreenAssistantManager: NSObject, ObservableObject {
    static let shared = ScreenAssistantManager()
    
    @Published var attachedFiles: [ScreenAssistantFile] = []
    @Published var isRecording: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var chatMessages: [ChatMessage] = []
    @Published var isLoading: Bool = false
    @Published var activeToolStatus: String?
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var activeRequest: URLSessionTask?
    private var toolRunContext: ToolRunContext?
    private var includeNativeToolsInRequest = true
    private var lastAIRequest: (message: String, files: [ScreenAssistantFile], provider: AIModelProvider)?

    private struct ToolRunContext {
        let originalMessage: String
        let provider: AIModelProvider
        var callCount: Int
        var files: [ScreenAssistantFile]
        var results: [String]
    }
    
    // Panel management
    private var chatMessagesPanel: ChatMessagesPanel?
    private var chatInputPanel: ChatInputPanel?
    
    // Directory for storing audio recordings
    static let audioDataDirectory: URL = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let audioDir = documentsPath.appendingPathComponent("ScreenAssistantAudio")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        
        return audioDir
    }()
    
    // Directory for storing screenshots
    static let screenshotDataDirectory: URL = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let screenshotDir = documentsPath.appendingPathComponent("ScreenAssistantScreenshots")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
        
        return screenshotDir
    }()
    
    private override init() {
        super.init()
        loadFilesFromDefaults()
    }
    
    deinit {
        stopRecording()
        closePanels()
    }
    
    // MARK: - Panel Management
    
    func showPanels() {
        // Close existing panels first
        closePanels()
        
        // Create and show chat messages panel (left side)
        chatMessagesPanel = ChatMessagesPanel()
        chatMessagesPanel?.positionOnLeftSide()
        chatMessagesPanel?.makeKeyAndOrderFront(nil)
        
        // Create and show input panel (center)
        chatInputPanel = ChatInputPanel()
        chatInputPanel?.positionInCenter()
        chatInputPanel?.makeKeyAndOrderFront(nil)
        
        // Focus on input panel for immediate typing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.chatInputPanel?.makeKey()
        }
    }
    
    func closePanels() {
        chatMessagesPanel?.close()
        chatInputPanel?.close()
        chatMessagesPanel = nil
        chatInputPanel = nil
    }
    
    func arePanelsVisible() -> Bool {
        return chatMessagesPanel?.isVisible == true || chatInputPanel?.isVisible == true
    }
    
    // MARK: - File Management
    
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else {
            print("⚠️ ScreenAssistant: No URLs provided to addFiles")
            return
        }
        
        print("📁 ScreenAssistant: Adding \(urls.count) files")
        
        let newFiles = urls.compactMap { url -> ScreenAssistantFile? in
            // Wrap in autoreleasepool to manage memory
            return autoreleasepool {
                do {
                    // Verify file exists
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        print("❌ ScreenAssistant: File does not exist at \(url.path)")
                        return nil
                    }
                    
                    // Verify file is readable
                    guard FileManager.default.isReadableFile(atPath: url.path) else {
                        print("❌ ScreenAssistant: File is not readable at \(url.path)")
                        return nil
                    }
                    
                    // Create file entry with error handling
                    let file = ScreenAssistantFile(fileURL: url)
                    print("✅ ScreenAssistant: Created file entry for \(file.name)")
                    return file
                    
                } catch {
                    print("❌ ScreenAssistant: Error creating file entry - \(error)")
                    return nil
                }
            }
        }
        
        guard !newFiles.isEmpty else {
            print("⚠️ ScreenAssistant: No valid files to add")
            return
        }
        
        // Ensure we're on the main thread for @Published property updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                print("❌ ScreenAssistant: Self deallocated during addFiles")
                return
            }
            
            self.attachedFiles.append(contentsOf: newFiles)
            print("📁 ScreenAssistant: Total attached files: \(self.attachedFiles.count)")
            
            // Save to defaults with error handling
            do {
                self.saveFilesToDefaults()
            } catch {
                print("❌ ScreenAssistant: Failed to save files after adding - \(error)")
            }
        }
    }
    
    func removeFile(_ file: ScreenAssistantFile) {
        attachedFiles.removeAll { $0.id == file.id }
        
        // Clean up audio file if it exists
        if let audioFileName = file.audioFileName {
            let audioURL = ScreenAssistantManager.audioDataDirectory.appendingPathComponent(audioFileName)
            try? FileManager.default.removeItem(at: audioURL)
        }
        
        saveFilesToDefaults()
    }
    
    func clearAllFiles() {
        // Clean up all audio files
        for file in attachedFiles {
            if let audioFileName = file.audioFileName {
                let audioURL = ScreenAssistantManager.audioDataDirectory.appendingPathComponent(audioFileName)
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        
        attachedFiles.removeAll()
        saveFilesToDefaults()
    }
    
    // MARK: - Audio Recording
    
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        guard !isRecording else { return }
        
        let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
        let audioURL = ScreenAssistantManager.audioDataDirectory.appendingPathComponent(fileName)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            
            isRecording = true
            recordingDuration = 0
            
            // Start timer for recording duration
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateRecordingDuration()
            }
            
            print("Started recording: \(fileName)")
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    private func stopRecording() {
        guard isRecording else { return }
        
        audioRecorder?.stop()
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        
        print("Stopped recording")
    }
    
    private func updateRecordingDuration() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recordingDuration = recorder.currentTime
    }
    
    // MARK: - Persistence
    
    private func saveFilesToDefaults() {
        do {
            let encoded = try JSONEncoder().encode(attachedFiles)
            UserDefaults.standard.set(encoded, forKey: "ScreenAssistantFiles")
            print("✅ ScreenAssistant: Saved \(attachedFiles.count) files to UserDefaults")
        } catch {
            print("❌ ScreenAssistant: Failed to save files to UserDefaults - \(error)")
            // Don't throw - this is a non-critical operation
        }
    }
    
    private func loadFilesFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: "ScreenAssistantFiles"),
              let decoded = try? JSONDecoder().decode([ScreenAssistantFile].self, from: data) else {
            return
        }
        
        attachedFiles = decoded
    }
    
    // MARK: - Chat Management
    
    func sendMessage(_ message: String) {
        print("📤 ScreenAssistant: Sending message - '\(message)'")
        print("📁 ScreenAssistant: Attached files count: \(attachedFiles.count)")
        
        // Add user message to chat
        let userMessage = ChatMessage(content: message, isFromUser: true, attachedFiles: attachedFiles.isEmpty ? nil : attachedFiles)
        chatMessages.append(userMessage)
        
        // Print attached files details
        for (index, file) in attachedFiles.enumerated() {
            print("📎 ScreenAssistant: File \(index + 1): \(file.name) (\(file.type.rawValue))")
        }
        
        // Clear input and files after sending
        let currentFiles = attachedFiles
        clearAllFiles()
        
        // Send to appropriate AI API based on selected provider
        let provider = Defaults[.selectedAIProvider]
        toolRunContext = ToolRunContext(
            originalMessage: message,
            provider: provider,
            callCount: 0,
            files: currentFiles,
            results: []
        )
        includeNativeToolsInRequest = true
        activeToolStatus = nil
        sendToAI(message: message, files: currentFiles, provider: provider)
    }
    
    private func sendToAI(message: String, files: [ScreenAssistantFile], provider: AIModelProvider) {
        print("🚀 ScreenAssistant: Making API request to \(provider.displayName)")
        lastAIRequest = (message, files, provider)
        isLoading = true
        
        switch provider {
        case .gemini:
            sendToGeminiAPI(message: message, files: files)
        case .openai:
            sendToOpenAIAPI(message: message, files: files)
        case .claude:
            sendToClaudeAPI(message: message, files: files)
        case .local:
            sendToLocalAPI(message: message, files: files)
        case .groq:
            sendToGroqAPI(message: message, files: files)
        case .custom:
            sendToCustomAPI(message: message, files: files)
        }
    }
    
    private func sendToGeminiAPI(message: String, files: [ScreenAssistantFile]) {
        let apiKey = Defaults[.geminiApiKey]
        guard !apiKey.isEmpty else {
            print("❌ ScreenAssistant: No Gemini API key configured")
            addAssistantMessage("Error: No Gemini API key configured. Please set your API key in model settings.")
            isLoading = false
            return
        }
        
        // Get selected model or default to gemini-2.5-flash
        let selectedModel = Defaults[.selectedAIModel] ?? AIModel(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", supportsThinking: true)
        let modelId = selectedModel.id
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent?key=\(apiKey)") else {
            print("❌ ScreenAssistant: Invalid Gemini API URL")
            addAssistantMessage("Error: Invalid API URL")
            isLoading = false
            return
        }
        
        performAPIRequest(url: url, requestBody: buildGeminiRequestBody(message: message, files: files), provider: .gemini)
    }
    
    private func sendToOpenAIAPI(message: String, files: [ScreenAssistantFile]) {
        let apiKey = Defaults[.openaiApiKey]
        guard !apiKey.isEmpty else {
            print("❌ ScreenAssistant: No OpenAI API key configured")
            addAssistantMessage("Error: No OpenAI API key configured. Please set your API key in model settings.")
            isLoading = false
            return
        }
        
        // Get selected model or default to gpt-4o
        let selectedModel = Defaults[.selectedAIModel] ?? AIModel(id: "gpt-4o", name: "GPT-4o", supportsThinking: false)
        let modelId = selectedModel.id
        
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            print("❌ ScreenAssistant: Invalid OpenAI API URL")
            addAssistantMessage("Error: Invalid API URL")
            isLoading = false
            return
        }
        
        performOpenAIRequest(url: url, requestBody: buildOpenAIRequestBody(message: message, files: files, model: modelId), apiKey: apiKey)
    }

    private func sendToGroqAPI(message: String, files: [ScreenAssistantFile]) {
        let apiKey = Defaults[.groqApiKey]
        guard !apiKey.isEmpty else {
            print("❌ ScreenAssistant: No Groq API key configured")
            addAssistantMessage("Error: No Groq API key configured. Please set your API key in model settings.")
            isLoading = false
            return
        }
        
        // Get selected model or default to llama-3.3-70b-versatile
        let selectedModel = Defaults[.selectedAIModel]
        let modelId: String
        if let selectedId = selectedModel?.id,
           AIModelProvider.groq.supportedModels.contains(where: { $0.id == selectedId }) {
            modelId = selectedId
        } else {
            modelId = "llama-3.3-70b-versatile"
        }
        
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            print("❌ ScreenAssistant: Invalid Groq API URL")
            addAssistantMessage("Error: Invalid API URL")
            isLoading = false
            return
        }
        
        performOpenAIRequest(
            url: url,
            requestBody: buildOpenAIRequestBody(message: message, files: files, model: modelId),
            apiKey: apiKey,
            provider: .groq
        )
    }
    
    private func sendToClaudeAPI(message: String, files: [ScreenAssistantFile]) {
        let apiKey = Defaults[.claudeApiKey]
        guard !apiKey.isEmpty else {
            print("❌ ScreenAssistant: No Claude API key configured")
            addAssistantMessage("Error: No Claude API key configured. Please set your API key in model settings.")
            isLoading = false
            return
        }
        
        // Get selected model or default to claude-3-5-sonnet
        let selectedModel = Defaults[.selectedAIModel] ?? AIModel(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", supportsThinking: false)
        let modelId = selectedModel.id
        
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            print("❌ ScreenAssistant: Invalid Claude API URL")
            addAssistantMessage("Error: Invalid API URL")
            isLoading = false
            return
        }
        
        performClaudeRequest(url: url, requestBody: buildClaudeRequestBody(message: message, files: files, model: modelId), apiKey: apiKey)
    }
    
    private func sendToLocalAPI(message: String, files: [ScreenAssistantFile]) {
        let endpoint = Defaults[.localModelEndpoint]
        guard !endpoint.isEmpty else {
            print("❌ ScreenAssistant: No local endpoint configured")
            addAssistantMessage("Error: No local endpoint configured. Please set your endpoint in model settings.")
            isLoading = false
            return
        }
        
        guard let url = URL(string: "\(endpoint)/api/chat") else {
            print("❌ ScreenAssistant: Invalid local API URL")
            addAssistantMessage("Error: Invalid local API URL")
            isLoading = false
            return
        }
        
        performAPIRequest(url: url, requestBody: buildOllamaRequestBody(message: message, files: files), provider: .local)
    }

    private func sendToCustomAPI(message: String, files: [ScreenAssistantFile]) {
        let configuration = CustomAPIConfiguration.current

        do {
            let url = try configuration.resolvedURL()
            let headers = try configuration.requestHeaders()
            let requestBody = buildCustomAPIRequestBody(
                message: message,
                files: files,
                configuration: configuration
            )
            performCustomAPIRequest(url: url, requestBody: requestBody, headers: headers)
        } catch {
            print("❌ ScreenAssistant: Invalid custom API configuration - \(error)")
            addAssistantMessage("Error: \(error.localizedDescription)")
            isLoading = false
        }
    }
    
    // MARK: - API Request Builders
    
    private func buildGeminiRequestBody(message: String, files: [ScreenAssistantFile]) -> [String: Any] {
        var contents: [[String: Any]] = []
        
        // Add previous conversation messages (last 10 for context)
        let recentMessages = Array(chatMessages.suffix(10))
        for chatMessage in recentMessages {
            if chatMessage.id != chatMessages.last?.id { // Don't include the message we just added
                let role = chatMessage.isFromUser ? "user" : "model"
                contents.append([
                    "role": role,
                    "parts": [["text": chatMessage.content]]
                ])
            }
        }
        
        // Build current message parts
        var parts: [[String: Any]] = []
        
        // Add text part
        let contextualMessage = buildContextualMessage(message: message, files: files)
        parts.append(["text": contextualMessage])
        
        // Add file content for supported types using proper Gemini 2.5 APIs
        for file in files {
            if let filePart = createGeminiFilePart(for: file) {
                parts.append(filePart)
                print("📎 ScreenAssistant: Added file part for \(file.name)")
            }
        }
        
        // Add current message
        contents.append([
            "role": "user",
            "parts": parts
        ])
        
        var requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": ScreenAssistantToolCalling.systemPrompt]]
            ],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.7,
                "topP": 0.8,
                "topK": 40,
                "maxOutputTokens": 2048,
                "responseMimeType": "text/plain"
            ],
            "safetySettings": [
                [
                    "category": "HARM_CATEGORY_HARASSMENT",
                    "threshold": "BLOCK_MEDIUM_AND_ABOVE"
                ],
                [
                    "category": "HARM_CATEGORY_HATE_SPEECH", 
                    "threshold": "BLOCK_MEDIUM_AND_ABOVE"
                ],
                [
                    "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT",
                    "threshold": "BLOCK_MEDIUM_AND_ABOVE"
                ],
                [
                    "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
                    "threshold": "BLOCK_MEDIUM_AND_ABOVE"
                ]
            ]
        ]
        if includeNativeToolsInRequest {
            requestBody["tools"] = [[
                "functionDeclarations": ScreenAssistantToolCalling.geminiFunctionDeclarations
            ]]
        }
        
        // Add thinking configuration if enabled and model supports it
        let selectedModel = Defaults[.selectedAIModel]
        if selectedModel?.supportsThinking == true && Defaults[.enableThinkingMode] {
            requestBody["generationConfig"] = (requestBody["generationConfig"] as! [String: Any]).merging([
                "thinkingConfig": [
                    "thinkingBudget": 0 // 0 means unlimited thinking
                ]
            ]) { (_, new) in new }
        }
        
        return requestBody
    }
    
    private func buildOpenAIRequestBody(message: String, files: [ScreenAssistantFile], model: String) -> [String: Any] {
        var messages: [[String: Any]] = [[
            "role": "system",
            "content": ScreenAssistantToolCalling.systemPrompt
        ]]
        
        // Add previous conversation messages (last 10 for context)
        let recentMessages = Array(chatMessages.suffix(10))
        for chatMessage in recentMessages {
            if chatMessage.id != chatMessages.last?.id {
                let role = chatMessage.isFromUser ? "user" : "assistant"
                messages.append([
                    "role": role,
                    "content": chatMessage.content
                ])
            }
        }
        
        // Add current message
        let contextualMessage = buildContextualMessage(message: message, files: files)
        var content: [[String: Any]] = [["type": "text", "text": contextualMessage]]
        for file in files where file.type == .image {
            guard let image = customImageData(for: file) else { continue }
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"]
            ])
        }
        messages.append([
            "role": "user",
            "content": content.count == 1 ? contextualMessage : content
        ])
        
        var requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 2048
        ]
        if includeNativeToolsInRequest {
            requestBody["tools"] = ScreenAssistantToolCalling.openAITools
            requestBody["tool_choice"] = "auto"
        }
        return requestBody
    }
    
    private func buildClaudeRequestBody(message: String, files: [ScreenAssistantFile], model: String) -> [String: Any] {
        var messages: [[String: Any]] = []
        
        // Add previous conversation messages (last 10 for context)
        let recentMessages = Array(chatMessages.suffix(10))
        for chatMessage in recentMessages {
            if chatMessage.id != chatMessages.last?.id {
                let role = chatMessage.isFromUser ? "user" : "assistant"
                messages.append([
                    "role": role,
                    "content": chatMessage.content
                ])
            }
        }
        
        // Add current message
        let contextualMessage = buildContextualMessage(message: message, files: files)
        var content: [[String: Any]] = [["type": "text", "text": contextualMessage]]
        for file in files where file.type == .image {
            guard let image = customImageData(for: file) else { continue }
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.base64
                ]
            ])
        }
        messages.append(["role": "user", "content": content])
        
        var requestBody: [String: Any] = [
            "model": model,
            "system": ScreenAssistantToolCalling.systemPrompt,
            "max_tokens": 2048,
            "messages": messages
        ]
        if includeNativeToolsInRequest {
            requestBody["tools"] = ScreenAssistantToolCalling.anthropicTools
            requestBody["tool_choice"] = ["type": "auto"]
        }
        return requestBody
    }
    
    private func buildOllamaRequestBody(message: String, files: [ScreenAssistantFile]) -> [String: Any] {
        let selectedModel = Defaults[.selectedAIModel] ?? AIModel(id: "llama3.2", name: "Llama 3.2", supportsThinking: false)
        let contextualMessage = buildContextualMessage(message: message, files: files)
        
        var userMessage: [String: Any] = [
            "role": "user",
            "content": contextualMessage
        ]
        let images = files.compactMap { customImageData(for: $0)?.base64 }
        if !images.isEmpty {
            userMessage["images"] = images
        }

        var requestBody: [String: Any] = [
            "model": selectedModel.id,
            "messages": [
                [
                    "role": "system",
                    "content": ScreenAssistantToolCalling.systemPrompt
                ],
                userMessage
            ],
            "stream": false
        ]
        if includeNativeToolsInRequest {
            requestBody["tools"] = ScreenAssistantToolCalling.openAITools
        }
        return requestBody
    }

    private func buildCustomAPIRequestBody(
        message: String,
        files: [ScreenAssistantFile],
        configuration: CustomAPIConfiguration
    ) -> [String: Any] {
        switch configuration.format {
        case .openAI:
            return buildCustomOpenAIRequestBody(message: message, files: files, model: configuration.model)
        case .anthropic:
            return buildCustomAnthropicRequestBody(message: message, files: files, model: configuration.model)
        case .gemini:
            return buildGeminiRequestBody(message: message, files: files)
        case .ollama:
            return buildCustomOllamaRequestBody(message: message, files: files, model: configuration.model)
        }
    }

    private func buildCustomOpenAIRequestBody(message: String, files: [ScreenAssistantFile], model: String) -> [String: Any] {
        var messages = customConversationHistory(assistantRole: "assistant")
        messages.insert([
            "role": "system",
            "content": ScreenAssistantToolCalling.systemPrompt
        ], at: 0)
        let textContent = buildContextualMessage(message: message, files: files) + customTextFileContents(files)
        var content: [[String: Any]] = [[
            "type": "text",
            "text": textContent
        ]]

        for file in files where file.type == .image {
            guard let image = customImageData(for: file) else { continue }
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"]
            ])
        }
        if content.count == 1 {
            messages.append(["role": "user", "content": textContent])
        } else {
            messages.append(["role": "user", "content": content])
        }

        var requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 2048
        ]
        if includeNativeToolsInRequest {
            requestBody["tools"] = ScreenAssistantToolCalling.openAITools
            requestBody["tool_choice"] = "auto"
        }
        return requestBody
    }

    private func buildCustomAnthropicRequestBody(message: String, files: [ScreenAssistantFile], model: String) -> [String: Any] {
        var messages = customConversationHistory(assistantRole: "assistant")
        var content: [[String: Any]] = [[
            "type": "text",
            "text": buildContextualMessage(message: message, files: files) + customTextFileContents(files)
        ]]

        for file in files where file.type == .image {
            guard let image = customImageData(for: file) else { continue }
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.base64
                ]
            ])
        }
        messages.append(["role": "user", "content": content])

        var requestBody: [String: Any] = [
            "model": model,
            "system": ScreenAssistantToolCalling.systemPrompt,
            "max_tokens": 2048,
            "messages": messages
        ]
        if includeNativeToolsInRequest {
            requestBody["tools"] = ScreenAssistantToolCalling.anthropicTools
            requestBody["tool_choice"] = ["type": "auto"]
        }
        return requestBody
    }

    private func buildCustomOllamaRequestBody(message: String, files: [ScreenAssistantFile], model: String) -> [String: Any] {
        var userMessage: [String: Any] = [
            "role": "user",
            "content": buildContextualMessage(message: message, files: files) + customTextFileContents(files)
        ]
        let images = files.compactMap { customImageData(for: $0)?.base64 }
        if !images.isEmpty {
            userMessage["images"] = images
        }

        var messages = customConversationHistory(assistantRole: "assistant")
        messages.insert([
            "role": "system",
            "content": ScreenAssistantToolCalling.systemPrompt
        ], at: 0)
        messages.append(userMessage)
        var requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]
        if includeNativeToolsInRequest {
            requestBody["tools"] = ScreenAssistantToolCalling.openAITools
        }
        return requestBody
    }

    private func customConversationHistory(assistantRole: String) -> [[String: Any]] {
        Array(chatMessages.suffix(10)).compactMap { chatMessage in
            guard chatMessage.id != chatMessages.last?.id else { return nil }
            return [
                "role": chatMessage.isFromUser ? "user" : assistantRole,
                "content": chatMessage.content
            ]
        }
    }

    private func customTextFileContents(_ files: [ScreenAssistantFile]) -> String {
        var result = ""
        for file in files where file.type == .document || file.type == .other {
            guard let fileURL = file.fileURL,
                  let url = URL(string: fileURL),
                  let contents = try? String(contentsOf: url) else { continue }
            result += "\n\nContents of \(file.name):\n\(contents)"
        }
        return result
    }

    private func customImageData(for file: ScreenAssistantFile) -> (mimeType: String, base64: String)? {
        guard file.type == .image,
              let fileURL = file.fileURL,
              let url = URL(string: fileURL),
              let data = try? Data(contentsOf: url) else { return nil }

        let mimeType: String
        switch url.pathExtension.lowercased() {
        case "png": mimeType = "image/png"
        case "gif": mimeType = "image/gif"
        case "webp": mimeType = "image/webp"
        case "heic": mimeType = "image/heic"
        default: mimeType = "image/jpeg"
        }
        return (mimeType, data.base64EncodedString())
    }
    
    // MARK: - API Request Performers
    
    private func performAPIRequest(url: URL, requestBody: [String: Any], provider: AIModelProvider) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: requestBody, options: .prettyPrinted)
            request.httpBody = jsonData
            
            print("📋 ScreenAssistant: Request body size: \(jsonData.count) bytes")
        } catch {
            print("❌ ScreenAssistant: Failed to encode request - \(error)")
            addAssistantMessage("Error: Failed to encode request - \(error.localizedDescription)")
            isLoading = false
            return
        }
        
        var task: URLSessionDataTask?
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentTask = task else { return }
                
                // Ensure this callback belongs to the current in-flight request
                guard self.activeRequest === currentTask else { return }
                
                self.isLoading = false
                self.activeRequest = nil
                
                self.handleResponse(data: data, response: response, error: error, provider: provider)
            }
        }
        
        activeRequest = task
        task?.resume()
    }
    
    private func performOpenAIRequest(url: URL, requestBody: [String: Any], apiKey: String, provider: AIModelProvider = .openai) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: requestBody, options: .prettyPrinted)
            request.httpBody = jsonData
        } catch {
            print("❌ ScreenAssistant: Failed to encode OpenAI request - \(error)")
            addAssistantMessage("Error: Failed to encode request - \(error.localizedDescription)")
            isLoading = false
            return
        }
        
        var task: URLSessionDataTask?
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentTask = task else { return }
                
                // Ensure this callback belongs to the current in-flight request
                guard self.activeRequest === currentTask else { return }
                
                self.isLoading = false
                self.activeRequest = nil
                
                self.handleResponse(data: data, response: response, error: error, provider: provider)
            }
        }
        
        activeRequest = task
        task?.resume()
    }
    
    private func performClaudeRequest(url: URL, requestBody: [String: Any], apiKey: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: requestBody, options: .prettyPrinted)
            request.httpBody = jsonData
        } catch {
            print("❌ ScreenAssistant: Failed to encode Claude request - \(error)")
            addAssistantMessage("Error: Failed to encode request - \(error.localizedDescription)")
            isLoading = false
            return
        }
        
        var task: URLSessionDataTask?
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentTask = task else { return }
                
                // Ensure this callback belongs to the current in-flight request
                guard self.activeRequest === currentTask else { return }
                
                self.isLoading = false
                self.activeRequest = nil
                
                self.handleResponse(data: data, response: response, error: error, provider: .claude)
            }
        }
        
        activeRequest = task
        task?.resume()
    }

    private func performCustomAPIRequest(url: URL, requestBody: [String: Any], headers: [String: String]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            print("❌ ScreenAssistant: Failed to encode custom API request - \(error)")
            addAssistantMessage("Error: Failed to encode request - \(error.localizedDescription)")
            isLoading = false
            return
        }

        var task: URLSessionDataTask?
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, let currentTask = task, self.activeRequest === currentTask else { return }
                self.isLoading = false
                self.activeRequest = nil
                self.handleResponse(data: data, response: response, error: error, provider: .custom)
            }
        }

        activeRequest = task
        task?.resume()
    }
    
    // MARK: - Response Handlers
    
    private func handleResponse(data: Data?, response: URLResponse?, error: Error?, provider: AIModelProvider) {
        // Check if the request was cancelled (e.g., by resetConversationContext)
        if let error = error as? NSError, error.code == NSURLErrorCancelled {
            print("ℹ️ ScreenAssistant: Request was cancelled")
            return
        }
        
        if let error = error {
            print("❌ ScreenAssistant: Network error - \(error)")
            addAssistantMessage("Error: \(error.localizedDescription)")
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            print("📊 ScreenAssistant: HTTP Status: \(httpResponse.statusCode)")
            if !(200..<300).contains(httpResponse.statusCode) {
                if [400, 422].contains(httpResponse.statusCode),
                   includeNativeToolsInRequest,
                   toolRunContext != nil,
                   let retry = lastAIRequest {
                    print("ℹ️ ScreenAssistant: API rejected native tools; retrying with text tool protocol")
                    includeNativeToolsInRequest = false
                    sendToAI(message: retry.message, files: retry.files, provider: retry.provider)
                    return
                }
                if provider == .custom, let data {
                    handleCustomAPIError(statusCode: httpResponse.statusCode, data: data)
                } else {
                    handleAPIError(statusCode: httpResponse.statusCode, provider: provider)
                }
                return
            }
        }
        
        guard let data = data else {
            print("❌ ScreenAssistant: No response data")
            addAssistantMessage("Error: No response data")
            return
        }
        
        print("📨 ScreenAssistant: Response data size: \(data.count) bytes")

        if let parsed = ScreenAssistantToolCalling.parseResponse(
            data: data,
            provider: provider,
            customFormat: Defaults[.customAPIFormat]
        ) {
            if let tool = parsed.tool {
                executeToolRequest(tool, provider: provider)
                return
            }
            if let text = parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                addAssistantMessage(text)
                return
            }
        }
        
        // Parse response based on provider
        switch provider {
        case .gemini:
            parseGeminiResponse(data: data)
        case .openai, .groq:
            parseOpenAIResponse(data: data)
        case .claude:
            parseClaudeResponse(data: data)
        case .local:
            parseOllamaResponse(data: data)
        case .custom:
            parseCustomAPIResponse(data: data, format: Defaults[.customAPIFormat])
        }
    }

    private func parseCustomAPIResponse(data: Data, format: CustomAPIFormat) {
        switch format {
        case .openAI:
            parseOpenAIResponse(data: data)
        case .anthropic:
            parseClaudeResponse(data: data)
        case .gemini:
            parseGeminiResponse(data: data)
        case .ollama:
            parseOllamaResponse(data: data)
        }
    }
    
    private func parseGeminiResponse(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("✅ ScreenAssistant: Successfully parsed Gemini JSON response")
                
                if let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let text = firstPart["text"] as? String {
                    
                    print("✅ ScreenAssistant: Got Gemini response text: \(text.prefix(100))...")
                    addAssistantMessage(text)
                } else {
                    if let error = json["error"] as? [String: Any] {
                        handleAPIError(error: error)
                    } else {
                        print("❌ ScreenAssistant: Unexpected Gemini response format")
                        addAssistantMessage("Error: Unexpected response format from Gemini")
                    }
                }
            }
        } catch {
            print("❌ ScreenAssistant: Gemini JSON parsing error - \(error)")
            addAssistantMessage("Error: Failed to parse response - \(error.localizedDescription)")
        }
    }
    
    private func parseOpenAIResponse(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("✅ ScreenAssistant: Successfully parsed OpenAI JSON response")
                
                if let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    
                    print("✅ ScreenAssistant: Got OpenAI response text: \(content.prefix(100))...")
                    addAssistantMessage(content)
                } else {
                    if let error = json["error"] as? [String: Any] {
                        handleOpenAIError(error: error)
                    } else {
                        print("❌ ScreenAssistant: Unexpected OpenAI response format")
                        addAssistantMessage("Error: Unexpected response format from OpenAI")
                    }
                }
            }
        } catch {
            print("❌ ScreenAssistant: OpenAI JSON parsing error - \(error)")
            addAssistantMessage("Error: Failed to parse response - \(error.localizedDescription)")
        }
    }
    
    private func parseClaudeResponse(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("✅ ScreenAssistant: Successfully parsed Claude JSON response")
                
                if let content = json["content"] as? [[String: Any]],
                   let firstContent = content.first,
                   let text = firstContent["text"] as? String {
                    
                    print("✅ ScreenAssistant: Got Claude response text: \(text.prefix(100))...")
                    addAssistantMessage(text)
                } else {
                    if let error = json["error"] as? [String: Any] {
                        handleClaudeError(error: error)
                    } else {
                        print("❌ ScreenAssistant: Unexpected Claude response format")
                        addAssistantMessage("Error: Unexpected response format from Claude")
                    }
                }
            }
        } catch {
            print("❌ ScreenAssistant: Claude JSON parsing error - \(error)")
            addAssistantMessage("Error: Failed to parse response - \(error.localizedDescription)")
        }
    }
    
    private func parseOllamaResponse(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("✅ ScreenAssistant: Successfully parsed Ollama JSON response")
                
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    
                    print("✅ ScreenAssistant: Got Ollama response text: \(content.prefix(100))...")
                    addAssistantMessage(content)
                } else {
                    print("❌ ScreenAssistant: Unexpected Ollama response format")
                    addAssistantMessage("Error: Unexpected response format from local model")
                }
            }
        } catch {
            print("❌ ScreenAssistant: Ollama JSON parsing error - \(error)")
            addAssistantMessage("Error: Failed to parse response - \(error.localizedDescription)")
        }
    }
    
    private func buildContextualMessage(message: String, files: [ScreenAssistantFile]) -> String {
        var contextualMessage = message
        
        // Add file context with specific instructions for different types
        if !files.isEmpty {
            contextualMessage += "\n\nI have attached the following files for your analysis:"
            
            var hasImages = false
            var hasDocuments = false
            var hasAudio = false
            var hasVideo = false
            
            for file in files {
                contextualMessage += "\n- \(file.name) (\(file.type.displayName))"
                
                switch file.type {
                case .image: hasImages = true
                case .document: hasDocuments = true
                case .audio: hasAudio = true
                case .video: hasVideo = true
                case .other: break
                }
            }
            
            // Add specific instructions based on file types
            contextualMessage += "\n\nPlease analyze these files in the context of my question. Specifically:"
            
            if hasImages {
                contextualMessage += "\n- For images: Describe what you see, identify objects, text, or patterns, and relate them to my question."
            }
            
            if hasDocuments {
                contextualMessage += "\n- For documents: Read and understand the content, extract key information, and provide insights relevant to my question."
            }
            
            if hasAudio {
                contextualMessage += "\n- For audio: Listen to and transcribe the audio content, identify speakers, topics, or sounds as relevant."
            }
            
            if hasVideo {
                contextualMessage += "\n- For video: Analyze both visual and audio content, describe actions, scenes, or dialogue as applicable."
            }
            
            contextualMessage += "\n\nProvide comprehensive insights that combine information from all attached files with your response to my question."
        }
        
        return contextualMessage
    }
    
    private func createGeminiFilePart(for file: ScreenAssistantFile) -> [String: Any]? {
        print("📎 ScreenAssistant: Processing file for Gemini 2.5: \(file.name) (\(file.type.rawValue))")
        
        guard let fileURL = file.fileURL, let url = URL(string: fileURL) else {
            print("❌ ScreenAssistant: No valid URL for file \(file.name)")
            return ["text": "File: \(file.name) (no valid URL)"]
        }
        
        switch file.type {
        case .image:
            return createGeminiImagePart(for: url, fileName: file.name)
        case .document:
            return createGeminiDocumentPart(for: url, fileName: file.name)
        case .audio:
            return createGeminiAudioPart(for: url, fileName: file.name)
        case .video:
            return createGeminiVideoPart(for: url, fileName: file.name)
        case .other:
            return createGeminiTextPart(for: url, fileName: file.name)
        }
    }
    
    private func createGeminiImagePart(for url: URL, fileName: String) -> [String: Any]? {
        print("🖼️ ScreenAssistant: Processing image file: \(fileName)")
        
        do {
            let imageData = try Data(contentsOf: url)
            let base64String = imageData.base64EncodedString()
            
            // Determine MIME type
            let mimeType: String
            let pathExtension = url.pathExtension.lowercased()
            switch pathExtension {
            case "jpg", "jpeg":
                mimeType = "image/jpeg"
            case "png":
                mimeType = "image/png"
            case "gif":
                mimeType = "image/gif"
            case "webp":
                mimeType = "image/webp"
            case "heic":
                mimeType = "image/heic"
            default:
                mimeType = "image/jpeg"
            }
            
            print("📎 ScreenAssistant: Image encoded - \(base64String.count) bytes, MIME: \(mimeType)")
            
            return [
                "inline_data": [
                    "mime_type": mimeType,
                    "data": base64String
                ]
            ]
        } catch {
            print("❌ ScreenAssistant: Failed to encode image \(fileName): \(error)")
            return ["text": "Image file: \(fileName) (failed to encode: \(error.localizedDescription))"]
        }
    }
    
    private func createGeminiDocumentPart(for url: URL, fileName: String) -> [String: Any]? {
        print("📄 ScreenAssistant: Processing document file: \(fileName)")
        
        let pathExtension = url.pathExtension.lowercased()
        
        if pathExtension == "pdf" {
            // Handle PDF files using base64 encoding for Gemini 2.5
            do {
                let pdfData = try Data(contentsOf: url)
                let base64String = pdfData.base64EncodedString()
                
                print("📎 ScreenAssistant: PDF encoded - \(base64String.count) bytes")
                
                return [
                    "inline_data": [
                        "mime_type": "application/pdf",
                        "data": base64String
                    ]
                ]
            } catch {
                print("❌ ScreenAssistant: Failed to encode PDF \(fileName): \(error)")
                return ["text": "PDF file: \(fileName) (failed to encode: \(error.localizedDescription))"]
            }
        } else {
            // Handle text-based documents
            do {
                let content = try String(contentsOf: url)
                print("📄 ScreenAssistant: Read document content (\(content.count) characters)")
                return ["text": "File content of \(fileName):\n\(content)"]
            } catch {
                print("❌ ScreenAssistant: Failed to read document \(fileName): \(error)")
                return ["text": "Document file: \(fileName) (could not read content: \(error.localizedDescription))"]
            }
        }
    }
    
    private func createGeminiAudioPart(for url: URL, fileName: String) -> [String: Any]? {
        print("🎵 ScreenAssistant: Processing audio file: \(fileName)")
        
        do {
            let audioData = try Data(contentsOf: url)
            let base64String = audioData.base64EncodedString()
            
            // Determine MIME type
            let mimeType: String
            let pathExtension = url.pathExtension.lowercased()
            switch pathExtension {
            case "mp3":
                mimeType = "audio/mpeg"
            case "wav":
                mimeType = "audio/wav"
            case "m4a":
                mimeType = "audio/mp4"
            case "aac":
                mimeType = "audio/aac"
            case "flac":
                mimeType = "audio/flac"
            default:
                mimeType = "audio/mpeg"
            }
            
            print("� ScreenAssistant: Audio encoded - \(base64String.count) bytes, MIME: \(mimeType)")
            
            return [
                "inline_data": [
                    "mime_type": mimeType,
                    "data": base64String
                ]
            ]
        } catch {
            print("❌ ScreenAssistant: Failed to encode audio \(fileName): \(error)")
            return ["text": "Audio file: \(fileName) (failed to encode: \(error.localizedDescription))"]
        }
    }
    
    private func createGeminiVideoPart(for url: URL, fileName: String) -> [String: Any]? {
        print("� ScreenAssistant: Processing video file: \(fileName)")
        
        do {
            let videoData = try Data(contentsOf: url)
            let base64String = videoData.base64EncodedString()
            
            // Determine MIME type
            let mimeType: String
            let pathExtension = url.pathExtension.lowercased()
            switch pathExtension {
            case "mp4":
                mimeType = "video/mp4"
            case "mov":
                mimeType = "video/quicktime"
            case "avi":
                mimeType = "video/x-msvideo"
            case "mkv":
                mimeType = "video/x-matroska"
            default:
                mimeType = "video/mp4"
            }
            
            print("📎 ScreenAssistant: Video encoded - \(base64String.count) bytes, MIME: \(mimeType)")
            
            return [
                "inline_data": [
                    "mime_type": mimeType,
                    "data": base64String
                ]
            ]
        } catch {
            print("❌ ScreenAssistant: Failed to encode video \(fileName): \(error)")
            return ["text": "Video file: \(fileName) (failed to encode: \(error.localizedDescription))"]
        }
    }
    
    private func createGeminiTextPart(for url: URL, fileName: String) -> [String: Any]? {
        print("📝 ScreenAssistant: Processing text file: \(fileName)")
        
        do {
            let content = try String(contentsOf: url)
            print("📄 ScreenAssistant: Read text content (\(content.count) characters)")
            return ["text": "File content of \(fileName):\n\(content)"]
        } catch {
            print("❌ ScreenAssistant: Failed to read text file \(fileName): \(error)")
            return ["text": "File: \(fileName) (could not read content: \(error.localizedDescription))"]
        }
    }
    
    func clearChat() {
        resetConversationContext()
    }

    func resetConversationContext() {
        // Cancel any in-flight request
        activeRequest?.cancel()
        activeRequest = nil
        toolRunContext = nil
        activeToolStatus = nil
        lastAIRequest = nil
        ScreenAssistantMediaCaptureManager.shared.cancelActiveCapture()
        
        isLoading = false
        chatMessages.removeAll()
        clearAllFiles()
    }
    
    private func addAssistantMessage(_ content: String) {
        print("💬 ScreenAssistant: Adding assistant message: \(content.prefix(100))...")
        toolRunContext = nil
        activeToolStatus = nil
        lastAIRequest = nil
        isLoading = false
        let assistantMessage = ChatMessage(content: content, isFromUser: false)
        chatMessages.append(assistantMessage)
    }

    private func executeToolRequest(_ request: ScreenAssistantToolRequest, provider: AIModelProvider) {
        guard var context = toolRunContext, context.provider == provider else {
            addAssistantMessage("The AI requested device context, but the original request is no longer active.")
            return
        }
        guard context.callCount < ScreenAssistantToolCalling.maximumCallsPerUserMessage else {
            addAssistantMessage("The AI reached the device-tool limit for this message. Please send a new request to continue.")
            return
        }

        context.callCount += 1
        toolRunContext = context
        activeToolStatus = request.tool.statusText
        isLoading = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await ScreenAssistantToolCalling.execute(request)
                guard var activeContext = self.toolRunContext,
                      activeContext.provider == provider else { return }
                activeContext.files.append(contentsOf: result.files)
                activeContext.results.append(result.summary)
                self.toolRunContext = activeContext
                self.activeToolStatus = nil
                self.sendToolResultToAI(activeContext)
            } catch {
                guard var activeContext = self.toolRunContext,
                      activeContext.provider == provider else { return }
                activeContext.results.append(
                    "Tool \(request.tool.rawValue) failed: \(error.localizedDescription)"
                )
                self.toolRunContext = activeContext
                self.activeToolStatus = nil
                self.sendToolResultToAI(activeContext)
            }
        }
    }

    private func sendToolResultToAI(_ context: ToolRunContext) {
        let results = context.results.map { "- \($0)" }.joined(separator: "\n")
        let followUp = """
        Continue the user's original request using the Atoll device-tool results below.

        Original request:
        \(context.originalMessage)

        Tool results:
        \(results)

        Any attached image is direct output from the requested device tool. If another device tool is truly needed, request it now; otherwise answer the original request directly. Do not ask the user to manually upload the same context.
        """
        sendToAI(message: followUp, files: context.files, provider: context.provider)
    }
    
    private func handleAPIError(statusCode: Int, provider: AIModelProvider) {
        let userFriendlyMessage: String
        
        switch statusCode {
        case 429:
            userFriendlyMessage = "🚫 **Rate Limited**\n\n\(provider.displayName) is currently rate limiting requests. Please wait a moment and try again."
        case 400:
            userFriendlyMessage = "❌ **Invalid Request**\n\nThere was an issue with your request to \(provider.displayName). Please check your message and attached files."
        case 401:
            userFriendlyMessage = "🔑 **Authentication Error**\n\nYour \(provider.displayName) API key appears to be invalid. Please check your API key in model settings."
        case 403:
            userFriendlyMessage = "🚫 **Access Denied**\n\nYour \(provider.displayName) API key doesn't have permission for this request."
        case 404:
            userFriendlyMessage = "🔍 **Model Not Found**\n\nThe requested model is not available on \(provider.displayName)."
        case 500, 502, 503:
            userFriendlyMessage = "⚠️ **Server Error**\n\n\(provider.displayName) servers are experiencing issues. Please try again in a few minutes."
        default:
            userFriendlyMessage = "❌ **API Error (\(statusCode))**\n\n\(provider.displayName) returned an error. Please try again."
        }
        
        addAssistantMessage(userFriendlyMessage)
    }

    private func handleCustomAPIError(statusCode: Int, data: Data) {
        var detail: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                detail = error["message"] as? String
            } else if let error = json["error"] as? String {
                detail = error
            } else {
                detail = (json["message"] as? String) ?? (json["detail"] as? String)
            }
        }
        if detail == nil {
            detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let message = detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The server did not include an error message."
        addAssistantMessage("❌ **Custom API Error (\(statusCode))**\n\n\(message)")
    }
    
    private func handleAPIError(error: [String: Any]) {
        guard let code = error["code"] as? Int,
              let message = error["message"] as? String else {
            print("❌ ScreenAssistant: Unknown API Error")
            addAssistantMessage("An unknown error occurred. Please try again.")
            return
        }
        
        print("❌ ScreenAssistant: API Error \(code) - \(message)")
        
        let userFriendlyMessage: String
        
        switch code {
        case 429:
            // Quota exceeded
            if message.contains("quota") || message.contains("exceeded") {
                userFriendlyMessage = "🚫 **API Quota Exceeded**\n\nYou've reached your API usage limit. This usually happens when:\n\n• Too many requests in a short time\n• Daily/monthly quota exceeded\n• Free tier limits reached\n\n**What you can do:**\n• Wait a few minutes and try again\n• Check your API billing\n• Consider upgrading your plan\n\n*The system will work again once the quota resets.*"
            } else {
                userFriendlyMessage = "⏰ **Rate Limited**\n\nToo many requests. Please wait a moment and try again."
            }
            
        case 400:
            userFriendlyMessage = "❌ **Invalid Request**\n\nThere was an issue with your request. Please check your message and attached files."
            
        case 401:
            userFriendlyMessage = "🔑 **Authentication Error**\n\nYour API key appears to be invalid. Please check your API key in settings."
            
        case 403:
            userFriendlyMessage = "🚫 **Access Denied**\n\nYour API key doesn't have permission for this request. Please check your API key settings."
            
        case 404:
            userFriendlyMessage = "🔍 **Model Not Found**\n\nThe requested AI model is not available. Please try again later."
            
        case 500, 502, 503:
            userFriendlyMessage = "⚠️ **Server Error**\n\nThe AI service is experiencing issues. Please try again in a few minutes."
            
        default:
            userFriendlyMessage = "❌ **API Error (\(code))**\n\n\(message.components(separatedBy: ".").first ?? message)"
        }
        
        addAssistantMessage(userFriendlyMessage)
    }
    
    private func handleOpenAIError(error: [String: Any]) {
        if let message = error["message"] as? String {
            let userFriendlyMessage = "❌ **OpenAI Error**\n\n\(message)"
            addAssistantMessage(userFriendlyMessage)
        } else {
            addAssistantMessage("❌ **OpenAI Error**\n\nAn unknown error occurred with OpenAI.")
        }
    }
    
    private func handleClaudeError(error: [String: Any]) {
        if let message = error["message"] as? String {
            let userFriendlyMessage = "❌ **Claude Error**\n\n\(message)"
            addAssistantMessage(userFriendlyMessage)
        } else {
            addAssistantMessage("❌ **Claude Error**\n\nAn unknown error occurred with Claude.")
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension ScreenAssistantManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        if flag {
            let fileName = recorder.url.lastPathComponent
            let displayName = "Recording \(DateFormatter.shortTime.string(from: Date()))"
            let audioFile = ScreenAssistantFile(audioFileName: fileName, name: displayName)
            attachedFiles.append(audioFile)
            saveFilesToDefaults()
            print("Recording saved: \(fileName)")
        } else {
            print("Recording failed")
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("Recording encode error: \(error?.localizedDescription ?? "Unknown error")")
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}

// MARK: - DateFormatter Extension

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
