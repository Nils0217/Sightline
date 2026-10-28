// labels: production, needs-review
//
//  ContentView.swift
//  Sightline
//
//  Created by Liu Nils on 10/27/26.
//

import SwiftUI

/// Root screen. Hosts the gate tests; only the selected one runs its AR session.
/// Switching tests discards the other test's in-memory state (its CSV stays in Documents).
struct ContentView: View {
    enum Test: String, CaseIterable, Identifiable {
        case g1 = "G1 hand"
        case g2 = "G2 target"
        case g3 = "G3 map"
        var id: Self { self }
    }

    @State private var test = Test.g3

    var body: some View {
        ZStack(alignment: .top) {
            switch test {
            case .g1: G1MeasureView()
            case .g2: G2MeasureView()
            case .g3: G3MeasureView()
            }
            Picker("Test", selection: $test) {
                ForEach(Test.allCases) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)
            .padding(.top, 4)
        }
    }
}

#Preview {
    ContentView()
}
