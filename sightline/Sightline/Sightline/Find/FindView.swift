// labels: production, needs-review
// Find-and-grab screen. The whole screen is one button (tap = speak a command / stop), so it
// works without sight. The camera view, dots and numbers are for sighted testers and the demo:
// green = target, red = fingertip.

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
            Text("hand→target \(model.handDistance.map { String(format: "%.1f cm", $0 * 100) } ?? "-") (\(model.handSource))  cue \(model.lastCue)")
            if let url = model.logURL {
                ShareLink("Log CSV", item: url).font(.caption.bold()).allowsHitTesting(true)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
        .accessibilityHidden(true)
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
        root.addChild(context.coordinator.tipDot)
        view.scene.addAnchor(root)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.place(context.coordinator.targetDot, at: model.target)
        context.coordinator.place(context.coordinator.tipDot, at: model.tip)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let targetDot = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [UnlitMaterial(color: .green)])
        let tipDot = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [UnlitMaterial(color: .red)])

        func place(_ dot: ModelEntity, at position: SIMD3<Float>?) {
            dot.isEnabled = position != nil
            if let position { dot.position = position }
        }
    }
}
