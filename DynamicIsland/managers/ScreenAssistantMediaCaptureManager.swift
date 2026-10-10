/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

enum ScreenAssistantAudioSource: String, Identifiable {
    case microphone
    case systemAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return String(localized: "Microphone")
        case .systemAudio: return String(localized: "System Audio")
        }
    }
}

/// Captures explicit, user-initiated multimedia context for the screen assistant.
/// Images are attached to the next message; live audio is converted to text first.
final class ScreenAssistantMediaCaptureManager: NSObject, ObservableObject {
    static let shared = ScreenAssistantMediaCaptureManager()

    @Published private(set) var isTranscribing = false
    @Published private(set) var activeAudioSource: ScreenAssistantAudioSource?
    @Published private(set) var transcript = ""
    @Published private(set) var isCapturingCamera = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    private let audioEngine = AVAudioEngine()
    private var microphoneTapInstalled = false
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var systemAudioStream: SCStream?
    private var systemAudioOutput: ScreenAssistantSystemAudioOutput?

    private let cameraQueue = DispatchQueue(label: "com.atoll.screen-assistant.camera", qos: .userInitiated)
    private var cameraSession: AVCaptureSession?
    private var cameraCaptureDelegate: ScreenAssistantCameraCaptureDelegate?

    private override init() {
        super.init()
    }

    deinit {
        stopTranscription()
        cameraSession?.stopRunning()
    }

    // MARK: - Speech transcription

    func toggleTranscription(source: ScreenAssistantAudioSource) {
        if isTranscribing, activeAudioSource == source {
            stopTranscription()
            return
        }

        if isTranscribing {
            stopTranscription()
        }

        requestSpeechAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.publishStatus(
                    String(localized: "Speech recognition permission is required."),
                    isError: true
                )
                return
            }

            switch source {
            case .microphone:
                self.requestMicrophoneAuthorizationAndStart()
            case .systemAudio:
                self.startSystemAudioTranscription()
            }
        }
    }

    func stopTranscription() {
        if microphoneTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        audioEngine.stop()

        systemAudioOutput?.recognitionRequest = nil
        if let stream = systemAudioStream {
            Task {
                try? await stream.stopCapture()
            }
        }
        systemAudioStream = nil
        systemAudioOutput = nil

        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil

        let hadTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isTranscribing = false
        activeAudioSource = nil
        publishStatus(
            hadTranscript
                ? String(localized: "Transcription added to the message.")
                : String(localized: "No speech was detected."),
            isError: !hadTranscript
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.isTranscribing else { return }
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
        }
    }

    private func requestSpeechAuthorization(completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion(status == .authorized)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func requestMicrophoneAuthorizationAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startMicrophoneTranscription()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startMicrophoneTranscription()
                    } else {
                        self.publishStatus(
                            String(localized: "Microphone permission is required."),
                            isError: true
                        )
                    }
                }
            }
        case .denied, .restricted:
            publishStatus(String(localized: "Microphone permission is required."), isError: true)
        @unknown default:
            publishStatus(String(localized: "Microphone permission is unavailable."), isError: true)
        }
    }

    private func prepareRecognition(source: ScreenAssistantAudioSource) -> SFSpeechAudioBufferRecognitionRequest? {
        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""

        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            publishStatus(String(localized: "Speech recognition is currently unavailable."), isError: true)
            return nil
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        speechRecognizer = recognizer
        recognitionRequest = request
        isTranscribing = true
        activeAudioSource = source
        publishStatus(
            source == .microphone
                ? String(localized: "Listening to the microphone…")
                : String(localized: "Listening to system audio…"),
            isError: false
        )

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.isTranscribing = false
                        self.activeAudioSource = nil
                        self.publishStatus(
                            String(localized: "Transcription added to the message."),
                            isError: false
                        )
                    }
                }

                if let error, self.isTranscribing {
                    self.failTranscription(error.localizedDescription)
                }
            }
        }

        return request
    }

    private func startMicrophoneTranscription() {
        guard let request = prepareRecognition(source: .microphone) else { return }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            failTranscription(String(localized: "No microphone input is available."))
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        microphoneTapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            failTranscription(error.localizedDescription)
        }
    }

    private func startSystemAudioTranscription() {
        guard let request = prepareRecognition(source: .systemAudio) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard let display = content.displays.first else {
                    throw ScreenAssistantMediaCaptureError.noDisplay
                }

                let excludedApplications = content.applications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                )
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 16_000
                configuration.channelCount = 1
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.showsCursor = false

                let output = ScreenAssistantSystemAudioOutput(recognitionRequest: request)
                output.onError = { [weak self] message in
                    DispatchQueue.main.async {
                        self?.failTranscription(message)
                    }
                }

                let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
                try stream.addStreamOutput(
                    output,
                    type: .audio,
                    sampleHandlerQueue: DispatchQueue(label: "com.atoll.screen-assistant.system-audio")
                )

                await MainActor.run {
                    self.systemAudioOutput = output
                    self.systemAudioStream = stream
                }
                try await stream.startCapture()
            } catch {
                await MainActor.run {
                    self.failTranscription(error.localizedDescription)
                }
            }
        }
    }

    private func failTranscription(_ message: String) {
        if microphoneTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        systemAudioOutput?.recognitionRequest = nil
        systemAudioOutput = nil
        systemAudioStream = nil
        isTranscribing = false
        activeAudioSource = nil
        publishStatus(message, isError: true)
    }

    // MARK: - Camera snapshot

    func captureCameraSnapshot() {
        guard !isCapturingCamera else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            takeCameraSnapshot()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.takeCameraSnapshot()
                    } else {
                        self.publishStatus(
                            String(localized: "Camera permission is required."),
                            isError: true
                        )
                    }
                }
            }
        case .denied, .restricted:
            publishStatus(String(localized: "Camera permission is required."), isError: true)
        @unknown default:
            publishStatus(String(localized: "Camera permission is unavailable."), isError: true)
        }
    }

    private func takeCameraSnapshot() {
        isCapturingCamera = true
        publishStatus(String(localized: "Capturing a camera photo…"), isError: false)

        cameraQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let device = AVCaptureDevice.default(for: .video) else {
                    throw ScreenAssistantMediaCaptureError.noCamera
                }

                let session = AVCaptureSession()
                session.sessionPreset = .photo
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCapturePhotoOutput()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    throw ScreenAssistantMediaCaptureError.cameraConfigurationFailed
                }
                session.addInput(input)
                session.addOutput(output)

                let delegate = ScreenAssistantCameraCaptureDelegate { [weak self, weak session] result in
                    session?.stopRunning()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.cameraSession = nil
                        self.cameraCaptureDelegate = nil
                        self.isCapturingCamera = false

                        switch result {
                        case .success(let data):
                            self.saveCameraPhoto(data)
                        case .failure(let error):
                            self.publishStatus(error.localizedDescription, isError: true)
                        }
                    }
                }

                self.cameraSession = session
                self.cameraCaptureDelegate = delegate
                session.startRunning()
                output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
            } catch {
                DispatchQueue.main.async {
                    self.isCapturingCamera = false
                    self.publishStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func saveCameraPhoto(_ data: Data) {
        let fileName = "camera_\(Int(Date().timeIntervalSince1970)).jpg"
        let url = ScreenAssistantManager.screenshotDataDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: url, options: .atomic)
            ScreenAssistantManager.shared.addFiles([url])
            publishStatus(String(localized: "Camera photo attached."), isError: false)
        } catch {
            publishStatus(error.localizedDescription, isError: true)
        }
    }

    private func publishStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}

private final class ScreenAssistantSystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var onError: ((String) -> Void)?

    init(recognitionRequest: SFSpeechAudioBufferRecognitionRequest) {
        self.recognitionRequest = recognitionRequest
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }
}

private final class ScreenAssistantCameraCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(ScreenAssistantMediaCaptureError.cameraEncodingFailed))
            return
        }
        completion(.success(data))
    }
}

private enum ScreenAssistantMediaCaptureError: LocalizedError {
    case noDisplay
    case noCamera
    case cameraConfigurationFailed
    case cameraEncodingFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return String(localized: "No display is available for system audio capture.")
        case .noCamera:
            return String(localized: "No camera is available.")
        case .cameraConfigurationFailed:
            return String(localized: "The camera could not be configured.")
        case .cameraEncodingFailed:
            return String(localized: "The camera photo could not be encoded.")
        }
    }
}
