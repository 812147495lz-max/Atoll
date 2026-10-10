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
import Defaults

private func applyModelSelectionCornerMask(_ view: NSView, radius: CGFloat) {
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.layer?.cornerRadius = radius
    view.layer?.backgroundColor = NSColor.clear.cgColor
    if #available(macOS 13.0, *) {
        view.layer?.cornerCurve = .continuous
    }
}

// MARK: - Model Selection Panel
class ModelSelectionPanel: NSPanel {
    
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        
        setupWindow()
        setupContentView()
    }
    
    override var canBecomeKey: Bool {
        return true  // Can receive focus for interaction
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    // Handle ESC key globally for the panel
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            close()
        } else {
            super.keyDown(with: event)
        }
    }
    
    private func setupWindow() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true  // Enable dragging
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isFloatingPanel = true
        
        styleMask.insert(.fullSizeContentView)
        
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary
        ]
        
        ScreenCaptureVisibilityManager.shared.register(self, scope: .panelsOnly)
        
        acceptsMouseMovedEvents = true
    }
    
    private func setupContentView() {
        let contentView = ModelSelectionView()
        let hostingView = NSHostingView(rootView: contentView)
        applyModelSelectionCornerMask(hostingView, radius: 16)
        self.contentView = hostingView
        
        // Set size for model selection panel
        let preferredSize = CGSize(width: 450, height: 600)
        hostingView.setFrameSize(preferredSize)
        setContentSize(preferredSize)
    }
    
    func positionInCenter() {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let panelFrame = frame
        
        // Position in the center of the screen
        let xPosition = (screenFrame.width - panelFrame.width) / 2 + screenFrame.minX
        let yPosition = (screenFrame.height - panelFrame.height) / 2 + screenFrame.minY
        
        setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
    }
    
    deinit {
        ScreenCaptureVisibilityManager.shared.unregister(self)
    }
}

// MARK: - Model Selection View
struct ModelSelectionView: View {
    private let primaryProviders: [AIModelProvider] = [.gemini, .openai, .claude, .local]
    @State private var selectedProvider: AIModelProvider = Defaults[.selectedAIProvider]
    @State private var selectedModel: AIModel? = Defaults[.selectedAIModel]
    @State private var enableThinking: Bool = Defaults[.enableThinkingMode]
    
    // API Keys
    @State private var geminiApiKey: String = Defaults[.geminiApiKey]
    @State private var openaiApiKey: String = Defaults[.openaiApiKey]
    @State private var claudeApiKey: String = Defaults[.claudeApiKey]
    @State private var localEndpoint: String = Defaults[.localModelEndpoint]
    @State private var groqApiKey: String = Defaults[.groqApiKey]
    @State private var customAPIName: String = Defaults[.customAPIName]
    @State private var customAPIFormat: CustomAPIFormat = Defaults[.customAPIFormat]
    @State private var customAPIEndpoint: String = Defaults[.customAPIEndpoint]
    @State private var customAPIModel: String = Defaults[.customAPIModel]
    @State private var customAPIKey: String = Defaults[.customAPIKey]
    @State private var customAPIAuthentication: CustomAPIAuthentication = Defaults[.customAPIAuthentication]
    @State private var customAPIAuthName: String = Defaults[.customAPIAuthName]
    @State private var customAPIAuthPrefix: String = Defaults[.customAPIAuthPrefix]
    @State private var customAPIAdditionalHeaders: String = Defaults[.customAPIAdditionalHeaders]
    
    @State private var showingApiKeyAlert = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Model Selection")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Text("Choose your preferred AI model and configuration")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: closePanel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Close")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.gray.opacity(0.05))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // Provider Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AI Provider")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                            ForEach(primaryProviders) { provider in
                                ProviderCard(
                                    provider: provider,
                                    isSelected: selectedProvider == provider,
                                    onSelect: { selectProvider(provider) }
                                )
                            }
                        }

                        ProviderCard(
                            provider: .groq,
                            isSelected: selectedProvider == .groq,
                            onSelect: { selectProvider(.groq) },
                            isWide: true
                        )

                        ProviderCard(
                            provider: .custom,
                            isSelected: selectedProvider == .custom,
                            onSelect: { selectProvider(.custom) },
                            isWide: true
                        )
                    }
                    
                    Divider()
                    
                    // Model Selection
                    if !selectedProvider.supportedModels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(selectedProvider.displayName) Models")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            VStack(spacing: 8) {
                                ForEach(selectedProvider.supportedModels) { model in
                                    ModelRow(
                                        model: model,
                                        isSelected: selectedModel?.id == model.id,
                                        onSelect: { selectedModel = model }
                                    )
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Thinking Mode Toggle
                    if selectedModel?.supportsThinking == true {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Reasoning Mode")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Enable Thinking Mode")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    
                                    Text("Shows the model's reasoning process before the final answer")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Toggle("", isOn: $enableThinking)
                                    .toggleStyle(SwitchToggleStyle())
                            }
                            .padding(16)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(12)
                        }
                    }
                    
                    Divider()
                    
                    // API Configuration
                    VStack(alignment: .leading, spacing: 12) {
                        Text("API Configuration")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        ApiConfigurationSection(
                            provider: selectedProvider,
                            geminiApiKey: $geminiApiKey,
                            openaiApiKey: $openaiApiKey,
                            claudeApiKey: $claudeApiKey,
                            localEndpoint: $localEndpoint,
                            groqApiKey: $groqApiKey,
                            customAPIName: $customAPIName,
                            customAPIFormat: $customAPIFormat,
                            customAPIEndpoint: $customAPIEndpoint,
                            customAPIModel: $customAPIModel,
                            customAPIKey: $customAPIKey,
                            customAPIAuthentication: $customAPIAuthentication,
                            customAPIAuthName: $customAPIAuthName,
                            customAPIAuthPrefix: $customAPIAuthPrefix,
                            customAPIAdditionalHeaders: $customAPIAdditionalHeaders
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            
            Divider()
            
            // Footer with Save/Cancel buttons
            HStack {
                Button("Cancel") {
                    closePanel()
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                Button("Save Configuration") {
                    saveConfiguration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConfigurationValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(ModelSelectionVisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .onAppear {
            loadCurrentConfiguration()
        }
    }
    
    private var isConfigurationValid: Bool {
        switch selectedProvider {
        case .gemini:
            return !geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openai:
            return !openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .claude:
            return !claudeApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .local:
            return !localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .groq:
            return !groqApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .custom:
            let hasEndpointAndModel = !customAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !customAPIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasAuthentication = customAPIAuthentication == .none
                || (!customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !customAPIAuthName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            return hasEndpointAndModel && hasAuthentication
        }
    }
    
    private func loadCurrentConfiguration() {
        selectedProvider = Defaults[.selectedAIProvider]
        selectedModel = Defaults[.selectedAIModel]
        ensureValidModelSelection()
        enableThinking = Defaults[.enableThinkingMode]
        
        geminiApiKey = Defaults[.geminiApiKey]
        openaiApiKey = Defaults[.openaiApiKey]
        claudeApiKey = Defaults[.claudeApiKey]
        localEndpoint = Defaults[.localModelEndpoint]
        groqApiKey = Defaults[.groqApiKey]
        customAPIName = Defaults[.customAPIName]
        customAPIFormat = Defaults[.customAPIFormat]
        customAPIEndpoint = Defaults[.customAPIEndpoint]
        customAPIModel = Defaults[.customAPIModel]
        customAPIKey = Defaults[.customAPIKey]
        customAPIAuthentication = Defaults[.customAPIAuthentication]
        customAPIAuthName = Defaults[.customAPIAuthName]
        customAPIAuthPrefix = Defaults[.customAPIAuthPrefix]
        customAPIAdditionalHeaders = Defaults[.customAPIAdditionalHeaders]
    }
    
    private func saveConfiguration() {
        ensureValidModelSelection()

        Defaults[.selectedAIProvider] = selectedProvider
        Defaults[.selectedAIModel] = selectedModel
        Defaults[.enableThinkingMode] = enableThinking
        
        Defaults[.geminiApiKey] = geminiApiKey
        Defaults[.openaiApiKey] = openaiApiKey
        Defaults[.claudeApiKey] = claudeApiKey
        Defaults[.localModelEndpoint] = localEndpoint
        Defaults[.groqApiKey] = groqApiKey
        Defaults[.customAPIName] = customAPIName
        Defaults[.customAPIFormat] = customAPIFormat
        Defaults[.customAPIEndpoint] = customAPIEndpoint
        Defaults[.customAPIModel] = customAPIModel
        Defaults[.customAPIKey] = customAPIKey
        Defaults[.customAPIAuthentication] = customAPIAuthentication
        Defaults[.customAPIAuthName] = customAPIAuthName
        Defaults[.customAPIAuthPrefix] = customAPIAuthPrefix
        Defaults[.customAPIAdditionalHeaders] = customAPIAdditionalHeaders
        
        closePanel()
        
        // Notify that configuration changed
        NotificationCenter.default.post(name: .aiModelConfigurationChanged, object: nil)
    }

    private func selectProvider(_ provider: AIModelProvider) {
        selectedProvider = provider
        ensureValidModelSelection()
    }

    private func ensureValidModelSelection() {
        if selectedModel == nil || !selectedProvider.supportedModels.contains(where: { $0.id == selectedModel?.id }) {
            selectedModel = selectedProvider.supportedModels.first
        }
    }
    
    private func closePanel() {
        if let window = NSApp.windows.first(where: { $0 is ModelSelectionPanel }) {
            window.close()
        }
    }
}

// MARK: - Provider Card
struct ProviderCard: View {
    private let wideCardMinHeight: CGFloat = 110
    let provider: AIModelProvider
    let isSelected: Bool
    let onSelect: () -> Void
    var isWide: Bool = false
    
    var body: some View {
        VStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(isSelected ? Color.blue : Color.gray.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                Image(systemName: iconForProvider(provider))
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .primary)
            }
            
            // Name and description
            VStack(spacing: 4) {
                Text(provider.displayName)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(provider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                )
        )
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .frame(maxWidth: .infinity, minHeight: isWide ? wideCardMinHeight : nil)
    }
    
    private func iconForProvider(_ provider: AIModelProvider) -> String {
        switch provider {
        case .gemini: return "sparkles"
        case .openai: return "brain.head.profile"
        case .claude: return "doc.text"
        case .local: return "server.rack"
        case .groq: return "bolt.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
}

// MARK: - Model Row
struct ModelRow: View {
    let model: AIModel
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.body)
                    .foregroundColor(.primary)
                
                if model.supportsThinking {
                    Text("Supports reasoning mode")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title3)
            } else {
                Circle()
                    .stroke(Color.gray.opacity(0.5), lineWidth: 2)
                    .frame(width: 20, height: 20)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        )
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - API Configuration Section
struct ApiConfigurationSection: View {
    let provider: AIModelProvider
    @Binding var geminiApiKey: String
    @Binding var openaiApiKey: String
    @Binding var claudeApiKey: String
    @Binding var localEndpoint: String
    @Binding var groqApiKey: String
    @Binding var customAPIName: String
    @Binding var customAPIFormat: CustomAPIFormat
    @Binding var customAPIEndpoint: String
    @Binding var customAPIModel: String
    @Binding var customAPIKey: String
    @Binding var customAPIAuthentication: CustomAPIAuthentication
    @Binding var customAPIAuthName: String
    @Binding var customAPIAuthPrefix: String
    @Binding var customAPIAdditionalHeaders: String
    
    var body: some View {
        VStack(spacing: 12) {
            switch provider {
            case .gemini:
                ApiKeyField(
                    title: "Gemini API Key",
                    placeholder: "Enter your Gemini API key",
                    value: $geminiApiKey,
                    helpText: "Get your API key from Google AI Studio"
                )
                
            case .openai:
                ApiKeyField(
                    title: "OpenAI API Key",
                    placeholder: "Enter your OpenAI API key",
                    value: $openaiApiKey,
                    helpText: "Get your API key from OpenAI Platform"
                )
                
            case .claude:
                ApiKeyField(
                    title: "Claude API Key",
                    placeholder: "Enter your Claude API key",
                    value: $claudeApiKey,
                    helpText: "Get your API key from Anthropic Console"
                )
                
            case .local:
                ApiKeyField(
                    title: "Local Endpoint",
                    placeholder: "http://localhost:11434",
                    value: $localEndpoint,
                    helpText: "Ollama or compatible API endpoint",
                    isSecure: false
                )
            case .groq:
                ApiKeyField(
                    title: "Groq API Key",
                    placeholder: "Enter your Groq API key",
                    value: $groqApiKey,
                    helpText: "Get your API key from Groq Console"
                )
            case .custom:
                CustomAPIConfigurationSection(
                    name: $customAPIName,
                    format: $customAPIFormat,
                    endpoint: $customAPIEndpoint,
                    model: $customAPIModel,
                    apiKey: $customAPIKey,
                    authentication: $customAPIAuthentication,
                    authName: $customAPIAuthName,
                    authPrefix: $customAPIAuthPrefix,
                    additionalHeaders: $customAPIAdditionalHeaders
                )
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

struct CustomAPIConfigurationSection: View {
    @Binding var name: String
    @Binding var format: CustomAPIFormat
    @Binding var endpoint: String
    @Binding var model: String
    @Binding var apiKey: String
    @Binding var authentication: CustomAPIAuthentication
    @Binding var authName: String
    @Binding var authPrefix: String
    @Binding var additionalHeaders: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApiKeyField(
                title: "Display Name",
                placeholder: "DeepSeek, OpenRouter, Company Gateway…",
                value: $name,
                helpText: "Shown in the screen assistant",
                isSecure: false
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("API Format")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Picker("API Format", selection: $format) {
                    ForEach(CustomAPIFormat.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .onChange(of: format) { newFormat in
                    applyAuthenticationDefaults(for: newFormat)
                }
            }

            ApiKeyField(
                title: "Endpoint URL",
                placeholder: "https://api.example.com/v1/chat/completions",
                value: $endpoint,
                helpText: "Use {model} in the URL when the protocol requires it",
                isSecure: false
            )

            ApiKeyField(
                title: "Model",
                placeholder: "deepseek-flash",
                value: $model,
                helpText: "The exact model ID accepted by the API",
                isSecure: false
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Authentication")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Picker("Authentication", selection: $authentication) {
                    ForEach(CustomAPIAuthentication.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
            }

            if authentication != .none {
                ApiKeyField(
                    title: "API Key",
                    placeholder: "Enter API key",
                    value: $apiKey,
                    helpText: "Used only with this custom provider"
                )

                ApiKeyField(
                    title: authentication == .query ? "Query Parameter" : "Header Name",
                    placeholder: authentication == .query ? "key" : "Authorization",
                    value: $authName,
                    helpText: authentication == .query ? "For example: key or api_key" : "For example: Authorization or x-api-key",
                    isSecure: false
                )
            }

            if authentication == .bearer || authentication == .header {
                ApiKeyField(
                    title: "Value Prefix",
                    placeholder: "Bearer ",
                    value: $authPrefix,
                    helpText: "Prepended to the API key; leave empty for x-api-key",
                    isSecure: false
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Additional Headers")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextEditor(text: $additionalHeaders)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 70)
                    .padding(6)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                Text("Optional, one per line: Header-Name: value")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func applyAuthenticationDefaults(for format: CustomAPIFormat) {
        switch format {
        case .openAI:
            authentication = .bearer
            authName = "Authorization"
            authPrefix = "Bearer "
        case .anthropic:
            authentication = .header
            authName = "x-api-key"
            authPrefix = ""
        case .gemini:
            authentication = .query
            authName = "key"
            authPrefix = ""
        case .ollama:
            authentication = .none
            authName = ""
            authPrefix = ""
        }
    }
}

// MARK: - API Key Field
struct ApiKeyField: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    let helpText: String
    var isSecure: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            if isSecure {
                SecureField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
            }
            
            Text(helpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Visual Effect View
struct ModelSelectionVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Notification Extension
extension Notification.Name {
    static let aiModelConfigurationChanged = Notification.Name("aiModelConfigurationChanged")
}
