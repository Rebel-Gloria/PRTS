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
    #if PRTS_DEV_CAPTURE
    @AppStorage("developer.showCommandEntry") private var showCommandEntry = true
    @State private var commandText = ""
    #endif
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
                            #if PRTS_DEV_CAPTURE
                        .overlay(alignment: .topLeading) {
                            // At accessibility text sizes the metrics would cover the controls.
                            if !dynamicTypeSize.isAccessibilitySize {
                                GeometryReader { bounds in
                                    ScrollView {
                                        HomeDemoOverlay(model: camera.model)
                                    }
                                    .frame(width: bounds.size.width, height: bounds.size.height)
                                    .clipped()
                                }
                            }
                        }

                            #endif

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
                        cancel: cancelPhotoPress,
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
                SettingsView(model: camera.model)
            }
            .sheet(isPresented: $isShowingUserGuide) {
                UserGuideView().environmentObject(speechManager)
            }
            .onChange(of: camera.state) { _, newState in
                if newState != .running {
                    liveCaption.stop()
                    photo.cancel()
                }
                guard scenePhase == .active, !isShowingSettings, !photo.busy,
                    textReading.phase == .idle, !liveCaption.suspendsFeedback, !guidanceSuppressed
                else { return }
                speechManager.announceCameraState(newState)
                if newState == .running { hapticManager.cameraStarted() }
            }
            .onReceive(pollTimer) { _ in
                // Text reading owns the voice until it ends; route speech would cut into the text.
                let reading = textReading.phase != .idle
                let suspendHaptics =
                    camera.suspendsFeedback
                    || photo.busy || reading
                    || isShowingSettings || isHoldingStop
                    || guidanceSuppressed || scenePhase != .active
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
                guard let message else { return }
                if UIAccessibility.isVoiceOverRunning {
                    SpeechManager.postQueuedAnnouncement(message)
                } else {
                    speechManager.speak(message)
                }
            }
            .onChange(of: photo.message) { _, message in
                // Photo progress ("正在描述"…) is shown under the button; VoiceOver reads it too.
                if !message.isEmpty, !photo.isAnnouncing, UIAccessibility.isVoiceOverRunning {
                    SpeechManager.postQueuedAnnouncement(message)
                }
            }
            .onChange(of: isShowingSettings) { _, shown in
                if shown {
                    liveCaption.stop()
                    photo.cancel()
                    textReading.terminate()
                    feedback.reset()
                    speechManager.cancelPerceptionSpeech()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { pointerCannotHold = Self.assistivePointerRunning }
                if phase != .active {
                    liveCaption.stop()
                    photo.cancel()
                    textReading.terminate()
                    stopHoldTask?.cancel()
                    stopHoldTask = nil
                    isHoldingStop = false
                    didCompleteStopHold = false
                    hapticManager.stopHoldFeedback()
                }
                camera.lifecycle(phase)
                if phase != .active {
                    feedback.reset()
                    speechManager.cancelPerceptionSpeech()
                }
                runPendingCommand()
            }
            .onAppear {
                camera.poll(suspendFeedback: true)
                speechManager.speakHomeScreen(cameraState: camera.state)
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
                if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    AVAudioSession.InterruptionType(rawValue: raw) == .began
                {
                    liveCaption.stop()
                    photo.cancel()
                    textReading.terminate()
                }
            }
            .onDisappear {
                liveCaption.stop()
                photo.cancel()
                textReading.terminate()
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

        .tint(.appAccent)
        .preferredColorScheme(.dark)
    }

    /// Low vision mode gives no guidance; the first-launch guide keeps it quiet while open.
    private var guidanceSuppressed: Bool { lowVisionMode || isShowingUserGuide }

    private var homeActionsAvailable: Bool { !isShowingSettings && !isShowingUserGuide }

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
        #if PRTS_DEV_CAPTURE
        // At accessibility sizes the column would reach the photo button in the middle of the preview.
        if showCommandEntry && !(isLargeText && camera.state == .running) { commandEntry }
        #endif
    }

    /// Tap alternative to holding the photo button: first tap starts the question, second sends it.
    private var askButton: some View {
        Button {
            if askingByTap {
                askingByTap = false
                photo.up()
            } else {
                liveCaption.cancelPress()
                liveCaption.interruptAnnouncement()
                photo.localized = { speechManager.interfaceString($0) }
                photo.down(
                    snapshot: { camera.model.snapshot.frame },
                    silence: { speechManager.stopCurrentSpeech() }
                )
                askingByTap = photo.busy
            }
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
        if textReading.phase != .idle && !isShowingSettings {
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
            .accessibilityLabel(
                Text("home.noPreview.title") + Text(verbatim: "，") + Text("home.noPreview.subtitle")
            )
            .accessibilityIdentifier("noPreviewNotice")
    }

    private var header: some View {
        HomeHeaderView(isLargeText: isLargeText) {
            hapticManager.buttonTapped()
            isShowingSettings = true
        }
    }

    private var cameraStatus: some View {
        CameraStatusView(state: camera.state, isLargeText: isLargeText)
    }

    #if PRTS_DEV_CAPTURE
    private var commandEntry: some View {
        (isLargeText ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
            TextField("home.command.placeholder", text: $commandText)
                .font(.body)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .glassSurface(in: Capsule())
                .submitLabel(.send)
                .onSubmit(submitCommand)
                .accessibilityIdentifier("backendCommandField")
            Button(action: submitCommand) {
                Text("home.command.send").frame(maxWidth: isLargeText ? .infinity : nil)
            }
            .glassButtonStyle(prominent: true)
            .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("backendCommandSend")
        }
        .accessibilityElement(children: .contain)
    }

    private func submitCommand() {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        commandText = ""
        switch command {
        case "开始", "start": startGuidance()
        case "停止", "stop": camera.stopCamera()
        case "状态", "status": speechManager.speak(camera.status)
        case "读文字", "ocr": toggleTextReading()
        default: speechManager.speak("只支持：开始、停止、状态、读文字。")
        }
        hapticManager.buttonTapped()
    }

    #endif

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

    private func startGuidance() {
        feedback.guidanceStarted()
        camera.startCamera()
    }

    private var operationMessage: String? {
        camera.model.errorMessage
            ?? camera.model.permissionMessage.map { speechManager.interfaceString($0) }
    }

    /// Starts the camera from a shortcut, or leaves text reading, once the app is active.
    private func runPendingCommand() {
        guard scenePhase == .active, commands.startRequested else { return }
        commands.startRequested = false
        isShowingSettings = false
        isShowingUserGuide = false
        startCameraFromButton()
    }

    private func photoDown() {
        guard homeActionsAvailable else { return }
        liveCaption.down(perform: performPhotoAction)
    }

    private func performPhotoAction(_ action: LiveCaptionPressState.Action) {
        guard homeActionsAvailable else { return }
        switch action {
        case .photo(let action):
            liveCaption.interruptAnnouncement()
            photo.localized = { speechManager.interfaceString($0) }
            if !photo.perform(
                action,
                snapshot: { camera.model.snapshot.frame },
                silence: { speechManager.stopCurrentSpeech() }
            ) {
                liveCaption.cancelPress()
            }
        case .start:
            photo.cancel()
            speechManager.stopCurrentSpeech()
            liveCaption.localized = { speechManager.interfaceString($0) }
            liveCaption.start(snapshot: { camera.model.snapshot.frame })
        case .stop:
            liveCaption.stop()
            liveCaption.announce(speechManager.interfaceString("liveCaption.off"))
        }
    }

    private func cancelPhotoPress() {
        liveCaption.cancelPress()
        photo.cancel()
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
