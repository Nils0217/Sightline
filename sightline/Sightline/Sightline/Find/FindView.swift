// labels: production, needs-review
// Find-and-grab screen. The whole screen is one button (tap = speak a command / stop), so it
// works without sight. The camera view, dots and numbers are for sighted testers and the demo:
// green = target, red = palm centre, small orange = visible fingertips.
// Export sits top-right *above* the full-screen button (it was untappable inside the panel).

import ARKit
import RealityKit
import SwiftUI

struct FindView: View {
    @State private var model = FindModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            FindARContainer(model: model).ignoresSafeArea()
            Button { model.tap() } label: { Color.clear.contentShape(Rectangle()) }
                .accessibilityLabel(buttonLabel)
                .accessibilityHint("Double tap, then say for example: find the cup.")
            panel.allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) { exportButton }
        .onAppear { model.start() }
        .onDisappear { model.pause() }
    }

    private var buttonLabel: String {
        switch model.phase {
        case .idle, .done: "Speak a command"
        case .listening: "Listening"
        case .grabbing: "Done, I have it"
        case .locating, .guiding: "Stop"
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(.title3.bold())
            Text("heard \"\(model.lastHeard)\"")
            Text("target \(model.targetName ?? "-")  SAM \(model.samCalls)/\(FindModel.maxSAMCalls)  tracking \(model.tracking)")
            Text("hand \(model.handStatus)  hand→target \(model.handDistance.map { String(format: "%.1f cm", $0 * 100) } ?? "-")  guide \(model.guidePhase)")
            Text("said \(model.lastCue)")
            Text("recordings \(model.recordings)")
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var exportButton: some View {
        if !model.exportURLs.isEmpty {
            ShareLink(items: model.exportURLs) {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.callout.bold())
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.top, 8).padding(.trailing, 12)
            .accessibilityLabel("Export logs and recordings")
        }
    }

    private var headline: String {
        switch model.phase {
        case .idle: "Tap anywhere and speak"
        case .listening: "Listening…"
        case .locating: "Looking for the \(model.targetName ?? "object")…"
        case .guiding: "Guiding to the \(model.targetName ?? "object")"
        case .grabbing: "Grab it — tap when you have it"
        case .done: "Done. Tap for a new search"
        }
    }
}

private struct FindARContainer: UIViewRepresentable {
    let model: FindModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = model.session
        view.renderOptions.insert(.disableMotionBlur)
        let root = AnchorEntity(world: .zero)
        root.addChild(context.coordinator.targetDot)
        root.addChild(context.coordinator.palmDot)
        context.coordinator.tipDots.forEach { root.addChild($0) }
        view.scene.addAnchor(root)
        model.arView = view
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.place(context.coordinator.targetDot, at: model.target)
        context.coordinator.place(context.coordinator.palmDot, at: model.palm)
        for (i, dot) in context.coordinator.tipDots.enumerated() {
            context.coordinator.place(dot, at: i < model.fingertips.count ? model.fingertips[i] : nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let targetDot = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [UnlitMaterial(color: .green)])
        let palmDot = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [UnlitMaterial(color: .red)])
        let tipDots = (0..<5).map { _ in
            ModelEntity(mesh: .generateSphere(radius: 0.004), materials: [UnlitMaterial(color: .orange)])
        }

        func place(_ dot: ModelEntity, at position: SIMD3<Float>?) {
            dot.isEnabled = position != nil
            if let position { dot.position = position }
        }
    }
}
