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

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var feedback = FeedbackCoordinator()
    @EnvironmentObject private var speechManager: SpeechManager
    @EnvironmentObject private var hapticManager: HapticManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var isHoldingStop = false
    @State private var stopHoldTask: Task<Void, Never>?
    @State private var didCompleteStopHold = false
    @State private var isShowingSettings = false
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

                VStack(spacing: 20) {
                    header

                    Spacer()
                        .frame(maxWidth:.infinity)
                        #if PRTS_DEV_CAPTURE
                        .overlay(alignment:.topLeading) {
                            GeometryReader { bounds in
                                ScrollView {
                                    HomeDemoOverlay(model:camera.model)
                                }
                                .frame(width:bounds.size.width,height:bounds.size.height)
                                .clipped()
                            }
                        }

                        #endif

                    cameraStatus
                    if let message = camera.model.errorMessage ?? camera.model.permissionMessage {
                        Text(message).font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("homeOperationError")
                    }
                    #if PRTS_DEV_CAPTURE
                    if showCommandEntry { commandEntry }
                    #endif
                    primaryButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView(model:camera.model)
            }
            .onChange(of: camera.state) { _, newState in
                guard scenePhase == .active,!isShowingSettings else { return }
                UIAccessibility.post(notification:.announcement,argument:speechManager.accessibilityAnnouncement(for:newState))
                speechManager.speakCameraState(newState)
                if newState == .running { hapticManager.cameraStarted() }
            }
            .onReceive(pollTimer) { _ in
                camera.poll(suspendFeedback:isShowingSettings || isHoldingStop || !hapticManager.isEnabled || scenePhase != .active)
                if !isShowingSettings,scenePhase == .active,let result = camera.latestSceneResult {
                    feedback.consume(result,speech:speechManager,haptics:hapticManager,
                                     announceCandidates:!camera.model.snapshot.pathOptions.enabled)
                    if !isHoldingStop { feedback.consumeDirection(camera.model.snapshot,speech:speechManager) }
                } else if !isShowingSettings,feedback.lastConsumedResultID != nil {
                    feedback.suspendResultFeedback(); speechManager.cancelPerceptionSpeech()
                }
            }
            .onChange(of:isShowingSettings) { _,shown in
                if shown {
                    feedback.reset()
                    speechManager.cancelPerceptionSpeech()
                }
            }
            .onChange(of:scenePhase) { _, phase in
                if phase != .active {
                    stopHoldTask?.cancel(); stopHoldTask = nil
                    isHoldingStop = false; didCompleteStopHold = false
                    hapticManager.stopHoldFeedback()
                }
                camera.lifecycle(phase)
                if phase != .active { feedback.reset(); speechManager.cancelPerceptionSpeech() }
            }
            .onAppear {
                camera.poll(suspendFeedback:true)
                speechManager.speakHomeScreen(cameraState:camera.state)
            }
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

    @ViewBuilder
    private var cameraSurface: some View {
        if camera.state == .running && !isShowingSettings {
            CameraPreview(camera: camera)
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
                Image("HomeLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
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

    #if PRTS_DEV_CAPTURE
    private var commandEntry: some View {
        HStack(spacing: 8) {
            TextField("home.command.placeholder", text: $commandText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(submitCommand)
                .accessibilityIdentifier("backendCommandField")
            Button("home.command.send", action: submitCommand)
                .buttonStyle(.borderedProminent)
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
        default: speechManager.speak("当前只支持：开始、停止、状态；自然语言模型尚未接入。")
        }
        hapticManager.buttonTapped()
    }

    #endif

    private var primaryButton: some View {
        Button {
            startCameraFromButton()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: camera.state == .running ? "stop.fill" : "play.fill")
                    .accessibilityHidden(true)

                Text(LocalizedStringKey(
                    camera.state == .running
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
            camera.state == .running
                ? "home.camera.button.stopLongPress"
                : "home.camera.button.start.label"
        ))
        .accessibilityHint(LocalizedStringKey(
            camera.state == .running
                ? "home.camera.button.stopLongPress.hint"
                : "home.camera.button.start.hint"
        ))
        .accessibilityIdentifier("cameraButton")
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
        guard camera.state != .running,
              !camera.state.isBusy,
              !isHoldingStop,
              !didCompleteStopHold else { return }

        hapticManager.buttonTapped()
        camera.startCamera()
    }
}

private extension Color {
    static let appBackground = Color(red: 0.025, green: 0.045, blue: 0.075)
    static let appAccent = Color(red: 0.25, green: 0.95, blue: 0.77)
    static let appButtonText = Color(red: 0.015, green: 0.12, blue: 0.10)
}
