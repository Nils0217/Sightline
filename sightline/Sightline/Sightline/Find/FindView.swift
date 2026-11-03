// labels: production, needs-review
// One screen, three gestures (v9, 2026-10-31): tap = start / stop (finish a room scan), double tap =
// "Is this it?" (case 2, 2026-11-01), long press = measure reach. VoiceOver: activate = double tap's action, magic tap = tap,
// named actions for the rest. Small buttons are for a sighted helper. Camera dots stay hidden from VoiceOver.

import ARKit
import RealityKit
import SwiftUI

struct FindView: View {
    @State private var model = FindModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            FindARContainer(model: model).ignoresSafeArea()
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { model.doubleTap() }
                .onTapGesture { model.tap() }
                .onLongPressGesture(minimumDuration: 0.8) { model.beginReachCalibration() }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(buttonLabel)
                .accessibilityValue(model.statusLine())
                .accessibilityHint("Two-finger double tap to start or stop.")
                // VoiceOver's double tap means the same as a double tap without VoiceOver ("Is this it?"),
                // so the spoken "Double tap if you have it" holds either way.
                .accessibilityAction { model.doubleTap() }
                .accessibilityAction(.magicTap) { model.tap() }
                .accessibilityAction(named: "Stop") { model.stop() }
                .accessibilityAction(named: "Status") { model.speakStatus() }
                .accessibilityAction(named: "Is this it?") { model.doubleTap() }
                .accessibilityAction(named: "Measure reach") { model.beginReachCalibration() }
                .accessibilityAction(named: "Switch speech engine") { model.toggleSTTEngine() }
            VStack(spacing: 8) {
                panel.allowsHitTesting(false)
                HStack {
                    Button("Stop", systemImage: "stop.fill") { model.stop() }
                    Button("Status", systemImage: "speaker.wave.2") { model.speakStatus() }
                    Button("Is this it?", systemImage: "questionmark.circle") { model.doubleTap() }
                        .disabled(![.guiding, .grabbing].contains(model.phase))
                    Button("Reach", systemImage: "ruler") { model.beginReachCalibration() }
                    Button(model.sttEngine == "muse" ? "Muse" : "Apple", systemImage: "waveform") { model.toggleSTTEngine() }
                }
                .buttonStyle(.bordered)
                .accessibilityHidden(true)  // the same actions are on the main element
            }
            .padding(.bottom, 12)
        }
        .overlay(alignment: .topTrailing) { exportButton }
        .onAppear { model.start() }
        .onDisappear { model.pause() }
    }

    private var buttonLabel: String {
        if model.reachDistance == nil { return "Press and hold to measure your reach" }
        return model.phase == .idle || model.phase == .done ? "Tap and say what to find" : "Tap to stop"
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(.title3.bold())
            Text("tap = start / stop · double tap = is this it? · hold = measure reach").foregroundStyle(.secondary)
            Text("reach \(model.reachDistance.map { "\(Int($0 * 100)) cm" } ?? "not measured")  heard \"\(model.lastHeard)\"")
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
        if model.calibrating { return "Measuring reach — hold still" }
        if model.reachDistance == nil { return "Hold your hand out, then press and hold" }
        switch model.phase {
        case .idle: return "Tap anywhere and speak"
        case .listening: return "Listening…"
        case .locating: return "Looking for the \(model.targetName ?? "object")…"
        case .searching: return "Scanning — turn slowly"
        case .guiding: return "Guiding to the \(model.targetName ?? "object")"
        case .grabbing: return model.lastCheckUnsure ? "Not sure — double tap if you have it" : "At your fingers — pick it up"
        case .verifying: return "Checking what you hold…"
        case .done: return "Done. Tap for a new search"
        case .mapping: return "Scanning the room — tap when done"
        }
    }
}

private struct FindARContainer: UIViewRepresentable {
    let model: FindModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = model.session
        view.renderOptions.insert(.disableMotionBlur)
        context.coordinator.anchorDots(in: view)
        context.coordinator.resets = model.sessionResets
        model.arView = view
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        // v9.4 device run: after the saved room failed to match, tracking was reset and no dot was drawn again.
        if context.coordinator.resets != model.sessionResets || context.coordinator.root?.scene == nil {
            context.coordinator.resets = model.sessionResets
            context.coordinator.anchorDots(in: view)
        }
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

        var root: AnchorEntity?
        var resets = 0

        /// A new world anchor at the origin holding every dot (the old one is removed).
        func anchorDots(in view: ARView) {
            if let root { view.scene.removeAnchor(root) }
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(targetDot)
            anchor.addChild(palmDot)
            tipDots.forEach { anchor.addChild($0) }
            view.scene.addAnchor(anchor)
            root = anchor
        }

        func place(_ dot: ModelEntity, at position: SIMD3<Float>?) {
            dot.isEnabled = position != nil
            if let position { dot.position = position }
        }
    }
}
