//
//  PRTSApp.swift
//  PRTS
//
//  Created by yuanyuan on 2026/7/24.
//

import SwiftUI

@main
struct PRTSApp: App {
    @StateObject private var speechManager = SpeechManager()
    @StateObject private var hapticManager = HapticManager()
    @StateObject private var backendBridge = PRTSBackendBridge()
    @StateObject private var arSession = PRTSARSessionCoordinator()
    @StateObject private var modelLoader = PRTSCoreMLModelLoader()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(speechManager)
                .environmentObject(hapticManager)
                .environmentObject(backendBridge)
                .environmentObject(arSession)
                .environmentObject(modelLoader)
                .environment(\.locale, speechManager.interfaceLocale)
        }
    }
}
