/// Restored product home screen. Technical overlays are embedded here instead of a separate demo mode.

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
    @StateObject private var feedback = FeedbackCoordinator()
    @StateObject private var textReading = TextReadingSession()
    @EnvironmentObject private var speechManager: SpeechManager
    @EnvironmentObject private var hapticManager: HapticManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingSettings = false
    @State private var isShowingUserGuide = false
    @AppStorage(UserGuide.shownKey) private var userGuideShown = false
    @AppStorage(Self.lowVisionKey) private var lowVisionMode = false
    /// For people with some sight: photos, questions and reading, without obstacle guidance.
    static let lowVisionKey = "app.lowVisionMode"
    /// AssistiveTouch (including dwell and eye tracking) and Switch Control deliver real
    /// touches but cannot hold a press, so held gestures get a tap alternative.
    @State private var pointerCannotHold = Self.assistivePointerRunning
    @State private var askingByTap = false
    @ObservedObject private var commands = HomeCommandCenter.shared
    @AppStorage(PhotoHardwareButtons.volumeKey) private var volumeButtons = true
    @AppStorage(TextReadingSession.threeFingerKey) private var threeFingerReading = true
    /// Skips the Metal preview for users who don't look at the screen. Analysis, guidance,
    /// haptics and photo capture read the shared snapshot, not the renderer.
    @AppStorage(Self.noPreviewKey) private var noPreview = false
    static let noPreviewKey = "display.noPreview"
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
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }

                if camera.state == .running && !isShowingSettings {
                    PhotoInteractionView(
                        photo: photo,
                        volumeButtons: volumeButtons,
                        snapshot: { camera.model.snapshot.frame },
                        silence: { speechManager.stopCurrentSpeech() },
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
            .background(ThreeFingerHold { if threeFingerReading { toggleTextReading() } })
            // VoiceOver two-finger double-tap restarts guidance if it stopped, or leaves reading.
            .accessibilityAction(.magicTap) {
                guard !isShowingSettings else { return }
                startCameraIfNeeded()
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView(model: camera.model)
            }
            .sheet(isPresented: $isShowingUserGuide) {
                UserGuideView().environmentObject(speechManager)
            }
            .onChange(of: camera.state) { _, newState in
                if newState != .running { photo.cancel() }
                guard scenePhase == .active, !isShowingSettings, !photo.busy,
                    textReading.phase == .idle
                else { return }
                speechManager.announceCameraState(newState)
                if newState == .running { hapticManager.cameraStarted() }
            }
            .onReceive(pollTimer) { _ in
                // Text reading owns the voice until it ends; route speech would cut into the text.
                let reading = textReading.phase != .idle
                // Low vision mode keeps the camera for photos and reading but gives no guidance.
                let quiet = lowVisionMode || isShowingUserGuide
                camera.poll(
                    suspendFeedback: photo.busy || reading || isShowingSettings
                        || quiet || scenePhase != .active
                )
                if !photo.busy, !reading, !isShowingSettings, !quiet,
                    scenePhase == .active
                {
                    let snapshot = camera.model.snapshot
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
                // Errors are otherwise only visible text; VoiceOver users must hear them.
                if let message, UIAccessibility.isVoiceOverRunning {
                    SpeechManager.postQueuedAnnouncement(message)
                }
            }
            .onChange(of: photo.message) { _, message in
                // Photo progress ("正在描述"…) is shown under the button; VoiceOver reads it too.
                if !message.isEmpty, UIAccessibility.isVoiceOverRunning {
                    SpeechManager.postQueuedAnnouncement(message)
                }
            }
            .onChange(of: isShowingSettings) { _, shown in
                if shown {
                    photo.cancel()
                    textReading.cancel()
                    feedback.reset()
                    speechManager.cancelPerceptionSpeech()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    photo.cancel()
                    textReading.cancel()
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
                // There is no start button: the camera runs whenever the app is open.
                startCameraIfNeeded()
                runPendingCommand()
            }
            .onChange(of: commands.startRequested) { _, _ in runPendingCommand() }
            .onChange(of: photo.busy) { _, busy in if !busy { askingByTap = false } }
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
                    photo.cancel()
                    textReading.cancel()
                }
            }
            .onDisappear {
                photo.cancel()
                textReading.cancel()
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

    private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

    private static var assistivePointerRunning: Bool {
        UIAccessibility.isAssistiveTouchRunning || UIAccessibility.isSwitchControlRunning
    }

    /// Accessibility text sizes use one scrolling column to keep controls readable.
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
        .disabled(photo.busy && !askingByTap)
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
            .accessibilityActions {
                if threeFingerReading { Button("home.ocr.action") { toggleTextReading() } }
            }
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
        case "开始", "start": camera.startCamera()
        case "停止", "stop": camera.stopCamera()
        case "状态", "status": speechManager.speak(camera.status)
        case "读文字", "ocr": toggleTextReading()
        default: speechManager.speak("只支持：开始、停止、状态、读文字。")
        }
        hapticManager.buttonTapped()
    }

    #endif

    private func startCameraIfNeeded() {
        // A start request or Magic Tap exits text reading and resumes its previous camera state.
        if textReading.phase != .idle {
            textReading.cancel()
            return
        }
        guard camera.state != .running,
            !camera.state.isBusy
        else { return }

        hapticManager.buttonTapped()
        camera.startCamera()
    }

    private var operationMessage: String? {
        camera.model.errorMessage ?? camera.model.permissionMessage
    }

    /// Consumes a pending start request once the home screen is active.
    private func runPendingCommand() {
        guard scenePhase == .active, commands.startRequested else { return }
        commands.startRequested = false
        isShowingSettings = false
        isShowingUserGuide = false
        startCameraIfNeeded()
    }

    /// Three-finger hold or the VoiceOver action: reading pauses guidance, which resumes after.
    private func toggleTextReading() {
        if textReading.phase != .idle {
            textReading.cancel()
            return
        }
        guard !isShowingSettings, !camera.state.isBusy else { return }
        photo.cancel()
        feedback.reset()
        speechManager.stopCurrentSpeech()
        let resumeGuidance = camera.state == .running
        if resumeGuidance { camera.stopCamera() }
        hapticManager.buttonTapped()
        textReading.localized = { key in speechManager.interfaceString(key) }
        textReading.finished = {
            if resumeGuidance && UIApplication.shared.applicationState == .active
                && !isShowingSettings
            {
                camera.startCamera()
            }
        }
        textReading.start(intro: resumeGuidance ? "ocr.start.pausedGuidance" : "ocr.start")
    }
}
