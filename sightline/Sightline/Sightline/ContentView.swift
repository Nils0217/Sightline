// labels: production, needs-review
//
//  ContentView.swift
//  Sightline
//
//  Created by Liu Nils on 10/27/26.
//

import SwiftUI

/// Root screen. For now it hosts the G1 hand-accuracy test (docs/G1_PLAN.md).
struct ContentView: View {
    var body: some View {
        G1MeasureView()
    }
}

#Preview {
    ContentView()
}
