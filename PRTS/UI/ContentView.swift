/// Restored product home screen. Technical overlays are embedded here instead of a separate demo mode.

//
//  ContentView.swift
//  PRTS
//
//  Created by yuanyuan on 2026/7/24.
//

import SwiftUI
import SpatialCore
import Combine
import UIKit
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var photo = PhotoDescriptionCoordinator()
    @StateObject private var feedback = FeedbackCoordinator()
    @StateObject private var textReading = TextReadingSession()
    @EnvironmentObject private var speechManager: SpeechManager
    @EnvironmentObject private var hapticManager: HapticManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isHoldingStop = false
    @State private var stopHoldTask: Task<Void, Never>?
    @State private var didCompleteStopHold = false
    @State private var isShowingSettings = false
    /// AssistiveTouch (including dwell and eye tracking) and Switch Control deliver real
    /// touches but cannot hold a press, so held gestures get a tap alternative.
    @State private var pointerCannotHold = Self.assistivePointerRunning
    @State private var askingByTap = false
    @ObservedObject private var commands = HomeCommandCenter.shared
    @AppStorage(PhotoCaptureButton.hardwareButtonsKey) private var photoHardwareButtons = true
    /// Skips the Metal preview for users who don't look at the screen. Analysis, guidance,
    /// haptics and photo capture read the shared snapshot, not the renderer.
    @AppStorage(Self.noPreviewKey) private var noPreview = false
    static let noPreviewKey = "display.noPreview"
    #if PRTS_DEV_CAPTURE
    @AppStorage("developer.showCommandEntry") private var showCommandEntry = true
    @State private var commandText = ""
    #endif
    private let pollTimer = Timer.publish(every:0.1,on:.main,in:.common).autoconnect()

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
                        .frame(maxWidth:.infinity)
                        #if PRTS_DEV_CAPTURE
                        .overlay(alignment:.topLeading) {
                            // At accessibility text sizes the metrics would cover the controls.
                            if !dynamicTypeSize.isAccessibilitySize { GeometryReader { bounds in
                                ScrollView {
                                    HomeDemoOverlay(model:camera.model)
                                }
                                .frame(width:bounds.size.width,height:bounds.size.height)
                                .clipped()
                            } }
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
                    PhotoCaptureButton(
                        down: { photo.down(snapshot: { camera.model.snapshot.frame }, silence: { speechManager.stopCurrentSpeech() }) },
                        up: { photo.up() }, cancel: { photo.cancel() },
                        strings: .init(label: speechManager.interfaceString("photo.button.label"),
                                       hint: speechManager.interfaceString("photo.button.hint"),
                                       ask: speechManager.interfaceString("photo.button.action.ask"),
                                       send: speechManager.interfaceString("photo.button.action.send")),
                        hardwareButtons: photoHardwareButtons)
                        .frame(width: 160, height: 160)
                        .overlay(alignment: .bottom) {
                            if !photo.message.isEmpty {
                                VStack(spacing: 8) {
                                    Text(photo.message).font(.caption)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .readableGlassPanel()
                                    if photo.busy {
                                        Button { photo.cancel() } label: {
                                            Text("home.photo.cancel").frame(minWidth: 44, minHeight: 44)
                                        }
                                        .glassButtonStyle()
                                    }
                                }.offset(y: 70)
                            }
                        }
                }

                if textReading.phase != .idle {
                    VStack(spacing: 4) {
                        Text("home.ocr.status").font(.headline)
                        Text("home.ocr.status.hint").font(.caption)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .readableGlassPanel()
                    .accessibilityElement(children: .combine)
                }
            }
            .background(ThreeFingerHold { toggleTextReading() })
            // VoiceOver two-finger double-tap runs the main action from anywhere on the screen.
            .accessibilityAction(.magicTap) {
                guard !isShowingSettings else { return }
                camera.state == .running ? stopFromAssistiveTechnology() : startCameraFromButton()
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView(model:camera.model)
            }
            .onChange(of: camera.state) { _, newState in
                if newState != .running { photo.cancel() }
                guard scenePhase == .active,!isShowingSettings, !photo.busy, textReading.phase == .idle else { return }
                speechManager.announceCameraState(newState)
                if newState == .running { hapticManager.cameraStarted() }
            }
            .onReceive(pollTimer) { _ in
                camera.poll(suspendFeedback:photo.busy || isShowingSettings || isHoldingStop || !hapticManager.isEnabled || scenePhase != .active)
                if !photo.busy, !isShowingSettings, !isHoldingStop, scenePhase == .active {
                    let snapshot = camera.model.snapshot
                    if snapshot.pathOptions.enabled && snapshot.pathUpdate.waypointGuidance != nil {
                        // One committed route state owns open/far/near speech. Do not also
                        // announce the raw centre sector or wait for a rendered floor.
                        feedback.consumeDirection(snapshot, speech: speechManager)
                    } else if let result = camera.latestSceneResult {
                        feedback.consume(result, speech:speechManager,
                                         announceCandidates:!snapshot.pathOptions.enabled)
                        feedback.consumeDirection(snapshot, speech:speechManager)
                    } else {
                        feedback.reset(); speechManager.cancelPerceptionSpeech()
                    }
                } else if !isShowingSettings {
                    feedback.reset(); speechManager.cancelPerceptionSpeech()
                }
            }
            .onChange(of: operationMessage) { _, message in
                // Errors are otherwise only visible text; VoiceOver users must hear them.
                if let message, UIAccessibility.isVoiceOverRunning { SpeechManager.postQueuedAnnouncement(message) }
            }
            .onChange(of: photo.message) { _, message in
                // Photo progress ("正在描述"…) is shown under the button; VoiceOver reads it too.
                if !message.isEmpty, UIAccessibility.isVoiceOverRunning { SpeechManager.postQueuedAnnouncement(message) }
            }
            .onChange(of:isShowingSettings) { _,shown in
                if shown {
                    photo.cancel()
                    textReading.cancel()
                    feedback.reset()
                    speechManager.cancelPerceptionSpeech()
                }
            }
            .onChange(of:scenePhase) { _, phase in
                if phase != .active {
                    photo.cancel()
                    textReading.cancel()
                    stopHoldTask?.cancel(); stopHoldTask = nil
                    isHoldingStop = false; didCompleteStopHold = false
                    hapticManager.stopHoldFeedback()
                }
                camera.lifecycle(phase)
                if phase != .active { feedback.reset(); speechManager.cancelPerceptionSpeech() }
                runPendingCommand()
            }
            .onAppear {
                camera.poll(suspendFeedback:true)
                speechManager.speakHomeScreen(cameraState:camera.state)
                runPendingCommand()
            }
            .onChange(of: commands.pending) { _, _ in runPendingCommand() }
            .onChange(of: photo.busy) { _, busy in if !busy { askingByTap = false } }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.assistiveTouchStatusDidChangeNotification)
                .merge(with: NotificationCenter.default.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification))) { _ in
                pointerCannotHold = Self.assistivePointerRunning
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   AVAudioSession.InterruptionType(rawValue: raw) == .began {
                    photo.cancel()
                    textReading.cancel()
                }
            }
            .onDisappear { photo.cancel(); textReading.cancel() }
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in
                camera.model.engine.diagnostics.event("memory_warning",details:"iOS notification",epoch:camera.model.snapshot.epoch)
            }
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.willTerminateNotification)) { _ in
                camera.model.engine.diagnostics.journal.flush(lifecycle:"will_terminate")
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
        cameraStatus
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
                photo.down(snapshot: { camera.model.snapshot.frame }, silence: { speechManager.stopCurrentSpeech() })
                askingByTap = photo.busy
            }
        } label: {
            Label(LocalizedStringKey(askingByTap ? "photo.button.action.send" : "photo.button.action.ask"),
                  systemImage: askingByTap ? "paperplane.fill" : "mic.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .glassButtonStyle()
        .disabled(photo.busy && !askingByTap)
        .accessibilityIdentifier("photoAskButton")
    }

    @ViewBuilder
    private var cameraSurface: some View {
        if camera.state == .running && !isShowingSettings {
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
        VStack(alignment: isLargeText ? .leading : .center, spacing: 18) {
            if !isLargeText {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
            }

            Text("home.camera.preview.title")
                .font(.title2.weight(.semibold))

            Text("home.camera.preview.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(isLargeText ? .leading : .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("home.camera.preview.off.label")
        .accessibilityHint("home.camera.preview.off.hint")
    }

    /// Sits above the status so it never collides with the photo button in the middle.
    private var noPreviewNotice: some View {
        Label("home.noPreview.title", systemImage: "eye.slash")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .glassSurface(in: Capsule())
            .accessibilityLabel(Text("home.noPreview.title") + Text(verbatim: "，") + Text("home.noPreview.subtitle"))
            .accessibilityIdentifier("noPreviewNotice")
    }

    private var header: some View {
        // Large accessibility text cannot fit brand and settings on one row; stack them.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) { brand; Spacer(); settingsButton }
            VStack(alignment: .leading, spacing: 12) { brand; settingsButton }
        }
        .padding(.top, 8)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("HomeLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            Text("PRTS")
                .font(.title2.weight(.bold))
        }
        // The brand is a title, not content; past accessibility1 it would push the controls away.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("app.home")
        .accessibilityAddTraits(.isHeader)
    }

    private var settingsButton: some View {
        Button {
            hapticManager.buttonTapped()
            isShowingSettings = true
        } label: {
            if isLargeText {
                // Icon-only so the header stays one row; long-press shows the Large Content Viewer.
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .dynamicTypeSize(.xxxLarge)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
                    .glassSurface(in: Circle(), interactive: true)
            } else {
                Label("home.settings.button", systemImage: "gearshape.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Capsule())
                    .glassSurface(in: Capsule(), interactive: true)
            }
        }
        .accessibilityShowsLargeContentViewer {
            Label("home.settings.button", systemImage: "gearshape.fill")
        }
        .accessibilityLabel("home.settings.label")
        .accessibilityHint("home.settings.hint")
        .accessibilityIdentifier("settingsButton")
    }

    private var cameraStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: camera.state.iconName)
                .foregroundStyle(camera.state.tintColor)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(camera.state.statusLocalizationKey))
                .font(.headline)
                .lineLimit(3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, isLargeText ? 12 : 0)
        .frame(maxWidth: isLargeText ? .infinity : nil, minHeight: 50, alignment: .leading)
        .glassSurface(in: isLargeText ? AnyShape(RoundedRectangle(cornerRadius: 24)) : AnyShape(Capsule()))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("home.camera.status.label")
        .accessibilityValue(LocalizedStringKey(camera.state.statusLocalizationKey))
        .accessibilityIdentifier("cameraStatus")
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
        let command = commandText.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        commandText = ""
        switch command {
        case "开始", "start": camera.startCamera()
        case "停止", "stop": camera.stopCamera()
        case "状态", "status": speechManager.speak(camera.status)
        default: speechManager.speak("只支持：开始、停止、状态。")
        }
        hapticManager.buttonTapped()
    }

    #endif

    private var primaryButton: some View {
        Button {
            if camera.state == .running && pointerCannotHold { stopFromAssistiveTechnology() } else { startCameraFromButton() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: camera.state == .running ? "stop.fill" : "play.fill")
                    .accessibilityHidden(true)

                Text(LocalizedStringKey(
                    camera.state != .running ? "home.camera.button.start"
                        : pointerCannotHold ? "home.camera.input.stop" : "home.camera.button.stopLongPress"
                ))
                .multilineTextAlignment(.center)
            }
            .font(.title2.weight(.bold))
            .padding(.vertical, isLargeText ? 12 : 0)
            .foregroundStyle(Color.appButtonText)
            .frame(maxWidth: .infinity, minHeight: 76)
            // Solid accent keeps the dark label at full contrast; the glass adds the system
            // press response and edge highlight without making the control translucent.
            .background(Color.appAccent, in: Capsule())
            .glassSurface(in: Capsule(), tint: .appAccent, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(camera.state.isBusy)
        .opacity(camera.state.isBusy ? 0.65 : 1)
        .accessibilityLabel(LocalizedStringKey(
            camera.state != .running ? "home.camera.button.start.label"
                : pointerCannotHold ? "home.camera.input.stop" : "home.camera.button.stopLongPress"
        ))
        .accessibilityHint(LocalizedStringKey(
            camera.state != .running ? "home.camera.button.start.hint"
                : pointerCannotHold ? "home.camera.button.stopTap.hint" : "home.camera.button.stopLongPress.hint"
        ))
        .accessibilityIdentifier("cameraButton")
        // Touch keeps the one-second hold. VoiceOver, Voice Control and Switch Control
        // cannot hold, so their activation stops directly.
        .accessibilityAction { camera.state == .running ? stopFromAssistiveTechnology() : startCameraFromButton() }
        .accessibilityAction(named: Text("home.camera.action.stop")) { stopFromAssistiveTechnology() }
        .accessibilityAction(named: Text("home.ocr.action")) { toggleTextReading() }
        .accessibilityInputLabels(camera.state == .running
            ? [Text("home.camera.input.stop"), Text("home.camera.button.stopLongPress")]
            : [Text("home.camera.input.start"), Text("home.camera.button.start.label")])
        .simultaneousGesture(stopGesture)
    }

    private var stopGesture: some Gesture {
        DragGesture(minimumDistance: 0)
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
            .onEnded { _ in
                stopHoldTask?.cancel()
                stopHoldTask = nil
                isHoldingStop = false
                hapticManager.stopHoldFeedback()
                DispatchQueue.main.async {
                    didCompleteStopHold = false
                }
            }
    }

    private func startCameraFromButton() {
        // During text reading the main button (and magic tap) leaves it instead.
        if textReading.phase != .idle { textReading.cancel(); return }
        guard camera.state != .running,
              !camera.state.isBusy,
              !isHoldingStop,
              !didCompleteStopHold else { return }

        hapticManager.buttonTapped()
        camera.startCamera()
    }

    private var operationMessage: String? { camera.model.errorMessage ?? camera.model.permissionMessage }

    /// Runs a Siri / Shortcuts / Action button command once the home screen is active.
    private func runPendingCommand() {
        guard scenePhase == .active, let command = commands.pending else { return }
        commands.pending = nil
        isShowingSettings = false
        switch command {
        case .start: startCameraFromButton()
        case .stop: stopFromAssistiveTechnology()
        case .describe:
            guard camera.state == .running else {
                speechManager.announce(speechManager.interfaceString("intent.describe.notRunning")); return
            }
            photo.down(snapshot: { camera.model.snapshot.frame }, silence: { speechManager.stopCurrentSpeech() })
            photo.up()
        }
    }

    /// Three-finger hold or the VoiceOver action: reading pauses guidance, which resumes after.
    private func toggleTextReading() {
        if textReading.phase != .idle { textReading.cancel(); return }
        guard !isShowingSettings, !camera.state.isBusy else { return }
        stopHoldTask?.cancel(); stopHoldTask = nil
        isHoldingStop = false; hapticManager.stopHoldFeedback()
        photo.cancel(); feedback.reset(); speechManager.stopCurrentSpeech()
        let resumeGuidance = camera.state == .running
        if resumeGuidance { camera.stopCamera() }
        hapticManager.buttonTapped()
        speechManager.announce(speechManager.interfaceString(resumeGuidance ? "ocr.start.pausedGuidance" : "ocr.start"))
        textReading.say = { key in speechManager.announce(speechManager.interfaceString(key)) }
        textReading.finished = {
            if resumeGuidance && UIApplication.shared.applicationState == .active && !isShowingSettings { camera.startCamera() }
        }
        textReading.start()
    }

    private func stopFromAssistiveTechnology() {
        guard camera.state == .running else { return }
        hapticManager.buttonTapped()
        camera.stopCamera()
    }
}

private extension Color {
    static let appBackground = Color(red: 0.025, green: 0.045, blue: 0.075)
    static let appAccent = Color(red: 0.25, green: 0.95, blue: 0.77)
    static let appButtonText = Color(red: 0.015, green: 0.12, blue: 0.10)
}
