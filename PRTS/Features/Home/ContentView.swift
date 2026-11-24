/// Home screen and cross-feature coordinator owning camera, description, caption, text-reading
/// and feedback coordinators; drives obstacle feedback with timer polling and handles
/// foreground/background transitions and Shortcuts commands.

//
//  ContentView.swift
//  PRTS
//
//

import AVFoundation
import Combine
import SpatialCore
import SwiftUI
import UIKit

struct ContentView: View {
    var startAutomatically = false
    var initialError: String?
    var restartApplication: (Bool, String?) -> Void = { _, _ in }
    @State private var initialStartHandled = false
    @State private var resettingRecording = false
    @StateObject private var camera = CameraManager()
    @StateObject private var photo = PhotoDescriptionCoordinator()
    @StateObject private var liveCaption = LiveCaptionSession()
    @StateObject private var feedback = FeedbackCoordinator()
    @StateObject private var textReading = TextReadingSession()
    @EnvironmentObject private var speechManager: SpeechManager
    @EnvironmentObject private var hapticManager: HapticManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isHoldingStop = false
    @State private var stopHoldTask: Task<Void, Never>?
    @State private var didCompleteStopHold = false
    @GestureState private var isPressingStop = false
    @State private var isShowingSettings = false
    @State private var audioInterrupted = false
    @State private var isShowingUserGuide = false
    @AppStorage(UserGuide.shownKey) private var userGuideShown = false
    @AppStorage(InteractionPreferences.lowVisionKey) private var lowVisionMode = false
    @AppStorage(InteractionPreferences.tapToStopKey) private var tapToStop = false
    /// AssistiveTouch (including dwell and eye tracking) and Switch Control deliver real
    /// touches but cannot hold a press, so held gestures get a tap alternative.
    @State private var pointerCannotHold = Self.assistivePointerRunning
    @State private var askingByTap = false
    @ObservedObject private var commands = HomeCommandCenter.shared
    @AppStorage(InteractionPreferences.volumeKey) private var volumeButtons = true
    @AppStorage(InteractionPreferences.threeFingerKey) private var threeFingerReading = true
    /// Skips the Metal preview for users who don't look at the screen. Analysis, guidance,
    /// haptics and photo capture read the shared snapshot, not the renderer.
    @AppStorage(InteractionPreferences.noPreviewKey) private var noPreview = false
    private let pollTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground
                    .ignoresSafeArea()

                cameraSurface

                LinearGradient(
                    colors: [.black.opacity(0.64), .clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .accessibilityHidden(true)

                if isLargeText {
                    largeTextLayout
                } else {
                    VStack(spacing: 20) {
                        header

                        Spacer()
                            .frame(maxWidth: .infinity)

                        GlassGroup(spacing: 0) {
                            VStack(spacing: 20) {
                                controls
                                primaryButton
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }

                if camera.state == .running && !isShowingSettings {
                    PhotoInteractionView(
                        message: liveCaption.message.isEmpty ? photo.message : liveCaption.message,
                        busy: photo.busy,
                        volumeButtons: volumeButtons,
                        down: photoDown,
                        up: { liveCaption.up(perform: performPhotoAction) },
                        cancelPress: {
                            liveCaption.cancelPress()
                            if !askingByTap { photo.cancelUnreleasedQuestion() }
                        },
                        cancelRequest: {
                            liveCaption.cancelPress()
                            photo.cancel()
                        },
                        setQuestionRecording: setQuestionRecording,
                        strings: .init(
                            label: speechManager.interfaceString("photo.button.label"),
                            hint: speechManager.interfaceString("photo.button.hint"),
                            ask: speechManager.interfaceString("photo.button.action.ask"),
                            send: speechManager.interfaceString("photo.button.action.send")
                        )
                    )
                }

                if textReading.phase != .idle {
                    TextReadingStatusView(framesSeen: textReading.framesSeen)
                }
            }
            .background(
                ThreeFingerHold {
                    if threeFingerReading && homeActionsAvailable { toggleTextReading() }
                }
            )
            // VoiceOver two-finger double-tap runs the main action from anywhere on the screen.
            .accessibilityAction(.magicTap) {
                guard homeActionsAvailable else { return }
                camera.state == .running ? stopFromAssistiveTechnology() : startCameraFromButton()
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView(model: camera.model, resetRecordings: resetRecordings)
            }
            .sheet(isPresented: $isShowingUserGuide) {
                UserGuideView().environmentObject(speechManager)
            }
            .onChange(of: camera.state) { _, newState in
                guard !resettingRecording else { return }
                if newState != .running && !isShowingSettings {
                    liveCaption.stop()
                    photo.cancel()
                }
                guard homeFeedbackEnabled, !photo.busy,
                    textReading.phase == .idle, !liveCaption.suspendsFeedback, !guidanceSuppressed
                else { return }
                speechManager.announceCameraState(newState)
                if newState == .running { hapticManager.cameraStarted() }
            }
            .onReceive(pollTimer) { _ in
                guard !resettingRecording else { return }
                // Text reading owns the voice until it ends; route speech would cut into the text.
                let reading = textReading.phase != .idle
                let suspendHaptics =
                    camera.suspendsFeedback
                    || photo.busy || reading
                    || isShowingSettings || isHoldingStop
                    || guidanceSuppressed || scenePhase != .active
                    || audioInterrupted
                // Live captions own the voice only. They run while the user walks, so
                // vibration keeps guiding; pausing it left no obstacle feedback at all.
                let suspendFeedback = suspendHaptics || liveCaption.suspendsFeedback
                camera.poll(suspendFeedback: suspendHaptics)
                let snapshot = camera.model.snapshot
                if suspendHaptics {
                    feedback.resetAlerts()
                } else if let alert = feedback.alert(snapshot) {
                    if snapshot.pathOptions.haptics { hapticManager.guidanceAlert() }
                    // Not perception speech: the branches below cancel that when no result
                    // is current, which is exactly when this has to be heard.
                    if alert == .lost && !suspendFeedback {
                        speechManager.speak(speechManager.interfaceString("speech.guidance.lost"))
                    }
                }
                if !suspendFeedback {
                    if snapshot.pathOptions.enabled && snapshot.pathUpdate.waypointGuidance != nil {
                        // One committed route state owns open/far/near speech. Do not also
                        // announce the raw centre sector or wait for a rendered floor.
                        feedback.consumeDirection(snapshot, speech: speechManager)
                    } else if let result = camera.latestSceneResult {
                        feedback.consume(
                            result,
                            speech: speechManager,
                            announceCandidates: !snapshot.pathOptions.enabled
                        )
                        feedback.consumeDirection(snapshot, speech: speechManager)
                    } else {
                        feedback.reset()
                        speechManager.cancelPerceptionSpeech()
                    }
                } else if !isShowingSettings {
                    feedback.reset()
                    speechManager.cancelPerceptionSpeech()
                }
            }
            .onChange(of: operationMessage) { _, message in
                // Errors are otherwise only visible text, which a blind user without VoiceOver
                // never learns of.
                guard let message, homeFeedbackEnabled else { return }
                if UIAccessibility.isVoiceOverRunning {
                    SpeechManager.postQueuedAnnouncement(message)
                } else {
                    speechManager.speak(message)
                }
            }
            .onChange(of: photo.message) { _, message in
                // Photo progress ("正在描述"…) is shown under the button; VoiceOver reads it too.
                if !message.isEmpty, !photo.isAnnouncing, homeFeedbackEnabled,
                    UIAccessibility.isVoiceOverRunning
                {
                    SpeechManager.postQueuedAnnouncement(message)
                }
            }
            .onChange(of: isShowingSettings) { _, shown in
                updateFeatureFeedback()
                if shown {
                    feedback.reset()
                    speechManager.stopCurrentSpeech()
                }
            }
            .onChange(of: lowVisionMode) { _, enabled in
                if !resettingRecording { camera.setLowVisionMode(enabled) }
            }
            .onChange(of: isShowingUserGuide) { _, _ in updateFeatureFeedback() }
            .onChange(of: scenePhase) { _, phase in
                guard !resettingRecording else { return }
                if phase == .active {
                    pointerCannotHold = Self.assistivePointerRunning
                    recoverInterruptedAudio()
                }
                updateFeatureFeedback()
                if phase != .active {
                    stopHoldTask?.cancel()
                    stopHoldTask = nil
                    isHoldingStop = false
                    didCompleteStopHold = false
                    hapticManager.stopHoldFeedback()
                }
                camera.lifecycle(phase)
                if phase != .active {
                    feedback.reset()
                    speechManager.stopCurrentSpeech()
                }
                runPendingCommand()
            }
            .onAppear {
                guard !resettingRecording else { return }
                camera.setLowVisionMode(lowVisionMode)
                if !initialStartHandled {
                    initialStartHandled = true
                    camera.model.errorMessage = initialError
                    if startAutomatically { camera.startCamera() }
                }
                updateFeatureFeedback()
                camera.poll(suspendFeedback: true)
                if homeFeedbackEnabled { speechManager.speakHomeScreen(cameraState: camera.state) }
                // The guide opens once, on the first launch. A launch from the Action button skips
                // it so guidance can start at once; the guide stays in Settings.
                if !userGuideShown && !commands.startRequested {
                    userGuideShown = true
                    isShowingUserGuide = true
                }
                runPendingCommand()
            }
            .onChange(of: commands.startRequested) { _, _ in runPendingCommand() }
            .onChange(of: photo.busy) { _, busy in if !busy { askingByTap = false } }
            .onChange(of: isPressingStop) { _, pressing in if !pressing { stopPressEnded() } }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIAccessibility.assistiveTouchStatusDidChangeNotification
                )
                .merge(
                    with: NotificationCenter.default.publisher(
                        for: UIAccessibility.switchControlStatusDidChangeNotification
                    )
                )
            ) { _ in
                pointerCannotHold = Self.assistivePointerRunning
            }
            .onReceive(
                NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            ) { notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let interruption = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                audioInterrupted = interruption == .began
                updateFeatureFeedback()
                if audioInterrupted {
                    speechManager.stopCurrentSpeech()
                }
            }
            .onDisappear {
                cancelPendingPhotoInput()
                photo.setFeedbackEnabled(false)
                liveCaption.setFeedbackEnabled(false)
                textReading.setFeedbackEnabled(false)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )
            ) { _ in
                camera.model.engine.diagnostics.event(
                    "memory_warning",
                    details: "iOS notification",
                    epoch: camera.model.snapshot.epoch
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            ) { _ in
                camera.model.engine.diagnostics.journal.flush(lifecycle: "will_terminate")
                speechManager.stopCurrentSpeech()
            }
        }

        .disabled(resettingRecording)
        .tint(.appAccent)
        .preferredColorScheme(.dark)
    }

    /// Low vision mode gives no guidance; the first-launch guide keeps it quiet while open.
    private var guidanceSuppressed: Bool { lowVisionMode || isShowingUserGuide }

    private var homeActionsAvailable: Bool {
        !resettingRecording && !isShowingSettings && !isShowingUserGuide
    }

    private var homeFeedbackEnabled: Bool {
        scenePhase == .active && homeActionsAvailable && !audioInterrupted
    }

    private func updateFeatureFeedback() {
        let enabled = homeFeedbackEnabled
        DevInteractionRecording.event(
            "feedback_gate",
            details: [
                "enabled": String(enabled), "settings": String(isShowingSettings),
                "userGuide": String(isShowingUserGuide),
                "audioInterrupted": String(audioInterrupted),
                "scenePhase": String(describing: scenePhase),
            ]
        )
        if !enabled { cancelPendingPhotoInput() }
        hapticManager.setFeedbackEnabled(enabled)
        photo.setFeedbackEnabled(enabled)
        liveCaption.setFeedbackEnabled(enabled)
        textReading.setFeedbackEnabled(enabled)
        if !enabled { camera.poll(suspendFeedback: true) }
    }

    private func resetRecordings() {
        #if PRTS_DEV
        guard !resettingRecording, !camera.model.exporting else { return }
        let resume = camera.requestedRunning
        resettingRecording = true
        camera.model.clearingRecordings = true
        updateFeatureFeedback()
        speechManager.stopCurrentSpeech()
        feedback.reset()
        stopHoldTask?.cancel()
        stopHoldTask = nil
        camera.model.engine.diagnostics.retire()
        RecordingStore.shared.clear(afterStopping: { @MainActor in
            // Cancel all producers before waiting for any one of them to drain.
            let photoShutdown = Task { await photo.shutdown() }
            let captionShutdown = Task { await liveCaption.shutdown() }
            let readingShutdown = Task { await textReading.shutdown() }
            await withCheckedContinuation { done in camera.stopCamera { done.resume() } }
            await photoShutdown.value
            await captionShutdown.value
            await readingShutdown.value
            await camera.model.engine.drainStoppedWork()
            await PhotoLocalModel.unload()
            await withCheckedContinuation { done in
                DevInteractionRecording.flush { done.resume() }
            }
        }) { result in
            Task { @MainActor in
                switch result {
                case .success: restartApplication(resume, nil)
                case .failure(let error): restartApplication(false, error.localizedDescription)
                }
            }
        }
        #endif
    }

    private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

    private static var assistivePointerRunning: Bool {
        // AssistiveTouch reports reliably only with Guided Access. The tap-to-stop setting
        // keeps stopping accessible when the system cannot report the user's input method.
        UIAccessibility.isAssistiveTouchRunning || UIAccessibility.isSwitchControlRunning
    }

    /// Accessibility text sizes: one scrolling column with the main button pinned to the
    /// bottom edge, so nothing is truncated or covered and the main action never scrolls away.
    private var largeTextLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if camera.state != .running || isShowingSettings { previewPlaceholder }
                GlassGroup(spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) { controls }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            primaryButton
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var controls: some View {
        #if PRTS_DEV
        Text("recording.home.privacy")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("recordingPrivacyNotice")
        #endif
        if noPreview && camera.state == .running && !isShowingSettings { noPreviewNotice }
        if camera.state != .idle { cameraStatus }
        if let message = operationMessage {
            Text(message).font(.callout.weight(.semibold)).foregroundStyle(.orange)
                .multilineTextAlignment(isLargeText ? .leading : .center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .readableGlassPanel()
                .accessibilityIdentifier("homeOperationError")
        }
        if pointerCannotHold && camera.state == .running && !isShowingSettings { askButton }
    }

    /// Tap alternative to holding the photo button: first tap starts the question, second sends it.
    private var askButton: some View {
        Button {
            _ = setQuestionRecording(!askingByTap)
        } label: {
            Label(
                LocalizedStringKey(
                    askingByTap ? "photo.button.action.send" : "photo.button.action.ask"
                ),
                systemImage: askingByTap ? "paperplane.fill" : "mic.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .glassButtonStyle()
        .disabled(liveCaption.isRunning || (photo.busy && !askingByTap))
        .accessibilityIdentifier("photoAskButton")
    }

    @ViewBuilder
    private var cameraSurface: some View {
        if resettingRecording {
            Color.appBackground
        } else if textReading.phase != .idle && !isShowingSettings {
            // Attaching the preview while the session is still being configured stalls the UI for seconds.
            if !noPreview && textReading.framesSeen > 0 {
                TextCameraPreview(session: textReading.camera.session)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        } else if camera.state == .running && !isShowingSettings {
            if !noPreview {
                CameraPreview(camera: camera)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        } else if !isLargeText {
            previewPlaceholder
        }
    }

    private var previewPlaceholder: some View {
        HomePlaceholderView(state: camera.state, isLargeText: isLargeText)
    }

    /// Sits above the status so it never collides with the photo button in the middle.
    private var noPreviewNotice: some View {
        Label("home.noPreview.title", systemImage: "eye.slash")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .glassSurface(in: Capsule())
            .accessibilityLabel("home.noPreview.title")
            .accessibilityValue("home.noPreview.subtitle")
            .accessibilityIdentifier("noPreviewNotice")
    }

    private var header: some View {
        HomeHeaderView(isLargeText: isLargeText) {
            hapticManager.buttonTapped()
            isShowingSettings = true
        }
    }

    private var cameraStatus: some View {
        CameraStatusView(
            state: camera.state,
            lowVisionMode: lowVisionMode,
            isLargeText: isLargeText
        )
    }

    private var primaryButton: some View {
        GuidanceButton(
            state: camera.state,
            pointerCannotHold: pointerCannotHold || tapToStop,
            stopHoldCompleted: didCompleteStopHold,
            isLargeText: isLargeText,
            threeFingerReading: threeFingerReading,
            stopGesture: stopGesture,
            start: startCameraFromButton,
            stop: stopFromAssistiveTechnology,
            readText: toggleTextReading
        )
    }

    private var stopGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressingStop) { _, pressing, _ in pressing = true }
            .onChanged { _ in
                guard camera.state == .running, !isHoldingStop else { return }

                isHoldingStop = true
                didCompleteStopHold = false
                hapticManager.startHoldFeedback()
                stopHoldTask?.cancel()
                stopHoldTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }

                    guard !Task.isCancelled, isHoldingStop, camera.state == .running else {
                        return
                    }

                    isHoldingStop = false
                    didCompleteStopHold = true
                    hapticManager.stopHoldFeedback()
                    camera.stopCamera()
                }
            }
    }

    /// A gesture state also resets when the system cancels the touch, which skips `onEnded`.
    private func stopPressEnded() {
        stopHoldTask?.cancel()
        stopHoldTask = nil
        isHoldingStop = false
        hapticManager.stopHoldFeedback()
        DispatchQueue.main.async {
            didCompleteStopHold = false
        }
    }

    private func startCameraFromButton() {
        // During text reading the main button (and magic tap) leaves it instead.
        if textReading.phase != .idle {
            textReading.cancel()
            return
        }
        guard camera.state != .running,
            !camera.state.isBusy,
            !isHoldingStop,
            !didCompleteStopHold
        else { return }

        hapticManager.buttonTapped()
        startGuidance()
    }

    private func recoverInterruptedAudio() {
        // An interruption may have no matching end notification. Retry only on a new
        // foreground/start action, never on the guidance timer.
        if audioInterrupted {
            audioInterrupted = !AudioSessionCoordinator.shared.resumeAfterInterruption()
        }
    }

    private func startGuidance() {
        if audioInterrupted {
            recoverInterruptedAudio()
            updateFeatureFeedback()
        }
        feedback.guidanceStarted()
        camera.startCamera()
    }

    private var operationMessage: String? {
        camera.model.errorMessage
            ?? camera.model.permissionMessage.map { speechManager.interfaceString($0) }
    }

    /// Starts the camera from a shortcut, or leaves text reading, once the app is active.
    private func runPendingCommand() {
        guard !resettingRecording, scenePhase == .active, commands.startRequested else { return }
        commands.startRequested = false
        isShowingSettings = false
        isShowingUserGuide = false
        startCameraFromButton()
    }

    /// Explicit accessibility actions must not be reinterpreted as a short tap or a triple press.
    private func setQuestionRecording(_ recording: Bool) -> Bool {
        guard homeFeedbackEnabled, camera.state == .running, !liveCaption.isRunning,
            recording ? !photo.busy : askingByTap && photo.busy
        else { return false }
        liveCaption.cancelPress()
        performPhotoAction(.photo(recording ? .startRecording : .stopRecording))
        askingByTap = recording && photo.busy
        return photo.busy
    }

    private func photoDown() {
        guard homeFeedbackEnabled else { return }
        liveCaption.down(perform: performPhotoAction)
    }

    private func performPhotoAction(_ action: LiveCaptionPressState.Action) {
        guard homeFeedbackEnabled else { return }
        switch action {
        case .photo(let action):
            liveCaption.interruptAnnouncement()
            photo.localized = { speechManager.interfaceString($0) }
            if !photo.perform(
                action,
                capture: { try camera.capturePhoto(longestSide: $0) },
                silence: { speechManager.stopCurrentSpeech() }
            ) {
                liveCaption.cancelPress()
            }
        case .start:
            photo.cancel()
            speechManager.stopCurrentSpeech()
            liveCaption.localized = { speechManager.interfaceString($0) }
            liveCaption.start(capture: { try camera.captureCaptionFrame() })
        case .stop:
            liveCaption.stop()
            liveCaption.announce(speechManager.interfaceString("liveCaption.off"))
        }
    }

    private func cancelPendingPhotoInput() {
        liveCaption.cancelPress()
        photo.cancelUnreleasedQuestion()
        askingByTap = false
    }

    /// Three-finger hold or the VoiceOver action: reading pauses guidance, which resumes after.
    private func toggleTextReading() {
        guard homeActionsAvailable else { return }
        if textReading.phase != .idle {
            textReading.cancel()
            return
        }
        guard !camera.state.isBusy else { return }
        stopHoldTask?.cancel()
        stopHoldTask = nil
        isHoldingStop = false
        hapticManager.stopHoldFeedback()
        liveCaption.stop()
        photo.cancel()
        feedback.reset()
        speechManager.stopCurrentSpeech()
        let resumeGuidance = camera.state == .running
        hapticManager.buttonTapped()
        textReading.localized = { key in speechManager.interfaceString(key) }
        textReading.finished = {
            // Read the app state now: scenePhase here is the value from when reading started.
            camera.finishTextReading(isActive: UIApplication.shared.applicationState == .active)
        }
        textReading.start(intro: resumeGuidance ? "ocr.start.pausedGuidance" : "ocr.start") {
            ready in
            camera.pauseForTextReading(completion: ready)
        }
    }

    private func stopFromAssistiveTechnology() {
        guard camera.state == .running else { return }
        hapticManager.buttonTapped()
        camera.stopCamera()
    }
}
