// labels: production, needs-review
//
//  SightlineApp.swift
//  Sightline
//
//  Created by Liu Nils on 10/27/26.
//

import SwiftUI

@main
struct SightlineApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Nils, 2026-11-02: the screen must not sleep while the app is open (the phone is on the chest, nobody
        // touches it; a locked screen stops the camera and the voice). Back to normal when the app leaves.
        .onChange(of: scenePhase, initial: true) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
    }
}
