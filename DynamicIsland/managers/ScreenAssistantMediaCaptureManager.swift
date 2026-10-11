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
    private var timedTranscriptionStop: DispatchWorkItem?
    private var automaticTranscriptionDuration: TimeInterval?
    private var automaticTranscriptionCompletion: ((Result<String, Error>) -> Void)?
    private var transcriptionGeneration = 0

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

    func transcribe(source: ScreenAssistantAudioSource, duration: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard automaticTranscriptionCompletion == nil, !isTranscribing else {
                continuation.resume(throwing: ScreenAssistantMediaCaptureError.captureInProgress)
                return
            }

            transcript = ""
            automaticTranscriptionDuration = min(max(duration, 2), 15)
            automaticTranscriptionCompletion = { result in
                continuation.resume(with: result)
            }
            toggleTranscription(source: source)
        }
    }

    func toggleTranscription(source: ScreenAssistantAudioSource) {
        if isTranscribing, activeAudioSource == source {
            stopTranscription()
            return
        }

        if isTranscribing {
            stopTranscription()
        }

        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        requestSpeechAuthorization { [weak self] granted in
            guard let self else { return }
            guard self.transcriptionGeneration == generation else { return }
            guard granted else {
                self.publishStatus(
                    String(localized: "Speech recognition permission is required."),
                    isError: true
                )
                self.finishAutomaticTranscription(
                    .failure(ScreenAssistantMediaCaptureError.speechRecognitionPermissionDenied)
                )
                return
            }

            switch source {
            case .microphone:
                self.requestMicrophoneAuthorizationAndStart(generation: generation)
            case .systemAudio:
                self.startSystemAudioTranscription(generation: generation)
            }
        }
    }

    func stopTranscription() {
        transcriptionGeneration += 1
        timedTranscriptionStop?.cancel()
        timedTranscriptionStop = nil

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
        finishAutomaticTranscription(
            hadTranscript
                ? .success(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
                : .failure(ScreenAssistantMediaCaptureError.noSpeechDetected)
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

    private func requestMicrophoneAuthorizationAndStart(generation: Int) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startMicrophoneTranscription(generation: generation)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.transcriptionGeneration == generation else { return }
                    if granted {
                        self.startMicrophoneTranscription(generation: generation)
                    } else {
                        self.publishStatus(
                            String(localized: "Microphone permission is required."),
                            isError: true
                        )
                        self.finishAutomaticTranscription(
                            .failure(ScreenAssistantMediaCaptureError.microphonePermissionDenied)
                        )
                    }
                }
            }
        case .denied, .restricted:
            publishStatus(String(localized: "Microphone permission is required."), isError: true)
            finishAutomaticTranscription(.failure(ScreenAssistantMediaCaptureError.microphonePermissionDenied))
        @unknown default:
            publishStatus(String(localized: "Microphone permission is unavailable."), isError: true)
            finishAutomaticTranscription(.failure(ScreenAssistantMediaCaptureError.microphonePermissionDenied))
        }
    }

    private func prepareRecognition(
        source: ScreenAssistantAudioSource,
        generation: Int
    ) -> SFSpeechAudioBufferRecognitionRequest? {
        guard transcriptionGeneration == generation else { return nil }
        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""

        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            publishStatus(String(localized: "Speech recognition is currently unavailable."), isError: true)
            finishAutomaticTranscription(
                .failure(ScreenAssistantMediaCaptureError.transcriptionFailed(
                    String(localized: "Speech recognition is currently unavailable.")
                ))
            )
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
                        self.stopTranscription()
                        return
                    }
                }

                if let error, self.isTranscribing {
                    self.failTranscription(error.localizedDescription)
                }
            }
        }

        return request
    }

    private func startMicrophoneTranscription(generation: Int) {
        guard let request = prepareRecognition(source: .microphone, generation: generation) else { return }

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
            scheduleAutomaticTranscriptionStopIfNeeded()
        } catch {
            failTranscription(error.localizedDescription)
        }
    }

    private func startSystemAudioTranscription(generation: Int) {
        guard let request = prepareRecognition(source: .systemAudio, generation: generation) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard await MainActor.run(body: { self.transcriptionGeneration == generation }) else {
                    return
                }
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
                    guard self.transcriptionGeneration == generation else { return }
                    self.systemAudioOutput = output
                    self.systemAudioStream = stream
                }
                guard await MainActor.run(body: { self.transcriptionGeneration == generation }) else {
                    return
                }
                try await stream.startCapture()
                guard await MainActor.run(body: { self.transcriptionGeneration == generation }) else {
                    try? await stream.stopCapture()
                    return
                }
                await MainActor.run {
                    self.scheduleAutomaticTranscriptionStopIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.failTranscription(error.localizedDescription)
                }
            }
        }
    }

    private func failTranscription(_ message: String) {
        transcriptionGeneration += 1
        timedTranscriptionStop?.cancel()
        timedTranscriptionStop = nil
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
        finishAutomaticTranscription(.failure(ScreenAssistantMediaCaptureError.transcriptionFailed(message)))
    }

    private func finishAutomaticTranscription(_ result: Result<String, Error>) {
        timedTranscriptionStop?.cancel()
        timedTranscriptionStop = nil
        automaticTranscriptionDuration = nil
        let completion = automaticTranscriptionCompletion
        automaticTranscriptionCompletion = nil
        completion?(result)
    }

    private func scheduleAutomaticTranscriptionStopIfNeeded() {
        guard let duration = automaticTranscriptionDuration,
              automaticTranscriptionCompletion != nil else { return }
        timedTranscriptionStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in
            self?.stopTranscription()
        }
        timedTranscriptionStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stop)
    }

    func cancelActiveCapture() {
        guard isTranscribing || automaticTranscriptionCompletion != nil else { return }
        failTranscription(String(localized: "Media capture was cancelled."))
    }

    // MARK: - Camera snapshot

    func captureCameraSnapshot(
        attachToAssistant: Bool = true,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        guard !isCapturingCamera else {
            completion?(.failure(ScreenAssistantMediaCaptureError.captureInProgress))
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            takeCameraSnapshot(attachToAssistant: attachToAssistant, completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.takeCameraSnapshot(attachToAssistant: attachToAssistant, completion: completion)
                    } else {
                        self.publishStatus(
                            String(localized: "Camera permission is required."),
                            isError: true
                        )
                        completion?(.failure(ScreenAssistantMediaCaptureError.cameraPermissionDenied))
                    }
                }
            }
        case .denied, .restricted:
            publishStatus(String(localized: "Camera permission is required."), isError: true)
            completion?(.failure(ScreenAssistantMediaCaptureError.cameraPermissionDenied))
        @unknown default:
            publishStatus(String(localized: "Camera permission is unavailable."), isError: true)
            completion?(.failure(ScreenAssistantMediaCaptureError.cameraPermissionDenied))
        }
    }

    func captureCameraPhoto() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            captureCameraSnapshot(attachToAssistant: false) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func takeCameraSnapshot(
        attachToAssistant: Bool,
        completion: ((Result<URL, Error>) -> Void)?
    ) {
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
                            let saved = self.saveCameraPhoto(data, attachToAssistant: attachToAssistant)
                            completion?(saved)
                        case .failure(let error):
                            self.publishStatus(error.localizedDescription, isError: true)
                            completion?(.failure(error))
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
                    completion?(.failure(error))
                }
            }
        }
    }

    private func saveCameraPhoto(_ data: Data, attachToAssistant: Bool) -> Result<URL, Error> {
        let fileName = "camera_\(Int(Date().timeIntervalSince1970)).jpg"
        let url = ScreenAssistantManager.screenshotDataDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: url, options: .atomic)
            if attachToAssistant {
                ScreenAssistantManager.shared.addFiles([url])
            }
            publishStatus(String(localized: "Camera photo attached."), isError: false)
            return .success(url)
        } catch {
            publishStatus(error.localizedDescription, isError: true)
            return .failure(error)
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
    case captureInProgress
    case noDisplay
    case noCamera
    case cameraPermissionDenied
    case cameraConfigurationFailed
    case cameraEncodingFailed
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied
    case noSpeechDetected
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .captureInProgress:
            return String(localized: "Another media capture is already in progress.")
        case .noDisplay:
            return String(localized: "No display is available for system audio capture.")
        case .noCamera:
            return String(localized: "No camera is available.")
        case .cameraPermissionDenied:
            return String(localized: "Camera permission is required.")
        case .cameraConfigurationFailed:
            return String(localized: "The camera could not be configured.")
        case .cameraEncodingFailed:
            return String(localized: "The camera photo could not be encoded.")
        case .microphonePermissionDenied:
            return String(localized: "Microphone permission is required.")
        case .speechRecognitionPermissionDenied:
            return String(localized: "Speech recognition permission is required.")
        case .noSpeechDetected:
            return String(localized: "No speech was detected.")
        case .transcriptionFailed(let message):
            return message
        }
    }
}
