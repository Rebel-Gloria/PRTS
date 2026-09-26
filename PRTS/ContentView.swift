//
//  ContentView.swift
//  PRTS
//
//  Created by yuanyuan on 2026/7/24.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @EnvironmentObject private var backend: PRTSBackendBridge
    @EnvironmentObject private var arSession: PRTSARSessionCoordinator
    @EnvironmentObject private var speechManager: SpeechManager
    @EnvironmentObject private var hapticManager: HapticManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAnnouncedInitialHome = false
    @State private var isReturningFromBackground = false
    @State private var isHoldingStop = false
    @State private var stopHoldTask: Task<Void, Never>?
    @State private var didCompleteStopHold = false
    @State private var isShowingSettings = false
    @State private var commandText = ""

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

                VStack(spacing: 20) {
                    header

                    Spacer()

                    cameraStatus
                    backendStatus
                    commandEntry
                    primaryButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .onChange(of: camera.state) { newState in
                if newState == .running {
                    backend.setActive(true)
                    camera.frameConsumer = backend
                } else if newState == .idle || newState == .permissionDenied {
                    backend.pause()
                }
                guard scenePhase != .background else { return }

                UIAccessibility.post(
                    notification: .announcement,
                    argument: speechManager.accessibilityAnnouncement(for: newState)
                )
                speechManager.speakCameraState(newState)

                if newState == .running {
                    hapticManager.cameraStarted()
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    isReturningFromBackground = true
                    stopHoldTask?.cancel()
                    stopHoldTask = nil
                    isHoldingStop = false
                    didCompleteStopHold = false
                    hapticManager.stopHoldFeedback()
                    arSession.pause()
                    backend.pause()
                } else if phase == .active {
                    backend.setActive(true)
                    camera.frameConsumer = backend
                    if isReturningFromBackground {
                        isReturningFromBackground = false
                        speechManager.speakHomeScreen(cameraState: camera.state)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                backend.handleMemoryWarning()
            }
            .onAppear {
                camera.frameConsumer = backend
                backend.onSpeechRequest = { [weak speechManager] request in speechManager?.enqueueBackendSpeech(request) }
                backend.onPlaybackChange = { [weak backend] active in backend?.setPlaybackFromTTS(active) }
                backend.onCancelSpeech = { [weak speechManager] in speechManager?.cancelBackendSpeech() }
                speechManager.backendPlaybackChanged = { [weak backend] active in backend?.setPlaybackFromTTS(active) }
                backend.onAttentionEvent = { [weak hapticManager] in hapticManager?.cameraStarted() }
                backend.onCue = { _, expiry in
                    guard expiry > ProcessInfo.processInfo.systemUptime else { return }
                    hapticManager.buttonTapped()
                }
                backend.initialize()
                if hasAnnouncedInitialHome {
                    guard !isReturningFromBackground else { return }
                    speechManager.speakHomeScreen(cameraState: camera.state)
                } else {
                    hasAnnouncedInitialHome = true
                    speechManager.speakHomeScreen(cameraState: camera.state)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                camera.frameConsumer = nil
                backend.close()
                speechManager.cancelBackendSpeech()
            }
        }
        .tint(.appAccent)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var cameraSurface: some View {
        if arSession.state == .running {
            PRTSARPreview(session: arSession.session)
                .ignoresSafeArea()
                .transition(.opacity)
                .accessibilityHidden(true)
        } else {
            VStack(spacing: 18) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)

                Text("home.camera.preview.title")
                    .font(.title2.weight(.semibold))

                Text("home.camera.preview.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("home.camera.preview.off.label")
            .accessibilityHint("home.camera.preview.off.hint")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Image(systemName: "eye.fill")
                    .font(.title2)
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)

                Text("PRTS")
                    .font(.title2.weight(.bold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("app.home")
            .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                hapticManager.buttonTapped()
                isShowingSettings = true
            } label: {
                Label("home.settings.button", systemImage: "gearshape.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    }
            }
            .accessibilityLabel("home.settings.label")
            .accessibilityHint("home.settings.hint")
            .accessibilityIdentifier("settingsButton")
        }
        .padding(.top, 8)
    }

    private var cameraStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: camera.state.iconName)
                .foregroundStyle(camera.state.tintColor)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(camera.state.statusLocalizationKey))
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 50)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("home.camera.status.label")
        .accessibilityValue(LocalizedStringKey(camera.state.statusLocalizationKey))
        .accessibilityIdentifier("cameraStatus")
    }

    private var backendStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(backend.status.message)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Text("Frames converted: \(backend.convertedFrameCount) · AR: \(arSession.state.label)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = backend.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var commandEntry: some View {
        HStack(spacing: 8) {
            TextField("Test command (e.g. 开始导航)", text: $commandText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(submitCommand)
                .accessibilityIdentifier("backendCommandField")
            Button("Send", action: submitCommand)
                .buttonStyle(.borderedProminent)
                .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("backendCommandSend")
        }
        .accessibilityElement(children: .contain)
    }

    private func submitCommand() {
        let intent = backend.pushText(commandText)
        commandText = ""
        if intent != nil { hapticManager.buttonTapped() }
    }

    private var primaryButton: some View {
        Button {
            startCameraFromButton()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: arSession.state == .running ? "stop.fill" : "play.fill")
                    .accessibilityHidden(true)

                Text(LocalizedStringKey(
                    arSession.state == .running
                        ? "home.camera.button.stopLongPress"
                        : "home.camera.button.start"
                ))
            }
            .font(.title2.weight(.bold))
            .foregroundStyle(Color.appButtonText)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.appAccent.opacity(0.3), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(camera.state.isBusy)
        .opacity(camera.state.isBusy ? 0.65 : 1)
        .accessibilityLabel(LocalizedStringKey(
            arSession.state == .running
                ? "home.camera.button.stopLongPress"
                : "home.camera.button.start.label"
        ))
        .accessibilityHint(LocalizedStringKey(
            arSession.state == .running
                ? "home.camera.button.stopLongPress.hint"
                : "home.camera.button.start.hint"
        ))
        .accessibilityIdentifier("cameraButton")
        .simultaneousGesture(stopGesture)
    }

    private var stopGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard arSession.state == .running, !isHoldingStop else { return }

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

                    guard !Task.isCancelled, isHoldingStop, arSession.state == .running else {
                        return
                    }

                    isHoldingStop = false
                    didCompleteStopHold = true
                    hapticManager.stopHoldFeedback()
                    arSession.pause()
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
        guard arSession.state != .running,
              !camera.state.isBusy,
              !isHoldingStop,
              !didCompleteStopHold else { return }

        hapticManager.buttonTapped()
        arSession.start()
    }
}

private extension Color {
    static let appBackground = Color(red: 0.025, green: 0.045, blue: 0.075)
    static let appAccent = Color(red: 0.25, green: 0.95, blue: 0.77)
    static let appButtonText = Color(red: 0.015, green: 0.12, blue: 0.10)
}
