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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(speechManager)
                .environmentObject(hapticManager)
                .environmentObject(backendBridge)
                .environment(\.locale, speechManager.interfaceLocale)
        }
    }
}
