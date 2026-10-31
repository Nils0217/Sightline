// labels: production, needs-review
// Accessible reach setup and fixed Stop/Status/Check/self-confirm controls.
// Main area starts when idle and stops every active task; long press always stops.
// Camera dots and telemetry remain hidden from VoiceOver. Device UI validation is pending.

import ARKit
import RealityKit
import SwiftUI

struct FindView: View {
    @State private var model = FindModel()
    @State private var showingSetup = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            FindARContainer(model: model).ignoresSafeArea()
            Color.clear.contentShape(Rectangle())
                .onTapGesture { primaryAction() }
                .onLongPressGesture(minimumDuration: 0.8) { model.stop() }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(buttonLabel)
                .accessibilityValue(model.statusLine())
                .accessibilityHint("When idle, say what to find. During a task, activate to stop. Separate controls provide status and object checks.")
                .accessibilityAction { primaryAction() }
                .accessibilityAction(.magicTap) { primaryAction() }
                .accessibilityAction(named: "Status") { model.speakStatus() }
                .accessibilityAction(named: "Stop") { model.stop() }
                .accessibilityAction(named: "New search") { model.newSearch() }
                .accessibilityAction(named: "Check held object") { model.checkHeldObject() }
                .accessibilityAction(named: "I confirm I have the object") { model.confirmHeldObject() }
            VStack(spacing: 8) {
                panel.allowsHitTesting(false)
                HStack {
                    Button("Stop", systemImage: "stop.fill") { model.stop() }
                        .accessibilityIdentifier("reach.stop")
                    Button("Status", systemImage: "speaker.wave.2") { model.speakStatus() }
                        .accessibilityIdentifier("reach.status")
                    Button("Check", systemImage: "viewfinder") { model.checkHeldObject() }
                        .disabled(![.guiding, .grabbing].contains(model.phase) || model.safetyMessage != nil || model.needsUserDecision)
                        .accessibilityIdentifier("reach.check")
                }
                .buttonStyle(.borderedProminent)
                if model.phase == .mapping {
                    Button("Finish scan and save") { model.finishRoomScan() }
                        .accessibilityIdentifier("reach.finishScan")
                }
                if model.needsUserDecision {
                    Button("New search") { model.newSearch() }
                        .accessibilityIdentifier("reach.newSearch")
                }
                HStack {
                    Button("I confirm I have it") { model.confirmHeldObject() }
                        .disabled(![.guiding, .grabbing, .verifying].contains(model.phase) || model.safetyMessage != nil)
                        .accessibilityHint("Records your own confirmation, separately from automatic verification.")
                        .accessibilityIdentifier("reach.userConfirm")
                    Button("Reach setup") { model.stop(); showingSetup = true; model.explainSetup() }
                        .accessibilityIdentifier("reach.setup")
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
        .overlay(alignment: .topTrailing) { exportButton }
        .onAppear { model.start() }
        .accessibilityAction(.magicTap) { primaryAction() }
        .onDisappear { model.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.reachDistance == nil { showingSetup = true; model.explainSetup() }
        }
        .onChange(of: model.reachDistance) { _, distance in
            if distance != nil { showingSetup = false }
        }
        .accessibilityHidden(showingSetup)
        .overlay {
            if showingSetup {
                ReachSetupView(model: model) { showingSetup = false }
            }
        }
    }

    private func primaryAction() {
        if showingSetup {
            if model.calibrating { model.stop() }
            else if model.reachDistance != nil { showingSetup = false }
            else { model.beginReachCalibration(hand: model.selectedHand) }
        } else if model.reachDistance == nil, model.phase == .idle {
            showingSetup = true
            model.explainSetup()
        } else { model.tap() }
    }

    private var buttonLabel: String {
        model.phase == .idle || model.phase == .done ? "Speak a command" : "Stop current task"
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(.title3.bold())
            Text("tap = start or stop · Status button = status · hold = stop").foregroundStyle(.secondary)
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
        case .searching: "Scanning — turn slowly"
        case .guiding: "Guiding to the \(model.targetName ?? "object")"
        case .grabbing: model.needsUserDecision ? "Not confirmed — confirm yourself, new search, or stop" : "Explore by touch — choose Check after picking up"
        case .verifying: "Checking what you hold…"
        case .done: "Done. Tap for a new search"
        case .mapping: "Scanning — Finish scan to save, Stop to discard"
        }
    }
}

private struct ReachSetupView: View {
    let model: FindModel
    var finish: () -> Void

    private func activate() {
        if model.calibrating { model.stop() }
        else if model.reachDistance != nil { finish() }
        else { model.beginReachCalibration(hand: model.selectedHand) }
    }

    private func close() {
        model.closeReachSetup()
        finish()
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Button("Close setup", action: close)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .accessibilityIdentifier("reach.setupClose")
                Button(action: activate) {
                    VStack(spacing: 24) {
                        Text(model.calibrating ? "Measuring. Keep still." : "Comfortable reach")
                            .font(.largeTitle.bold())
                        Text(model.calibrating ? "Tap anywhere here to stop." : "Secure the phone on your chest. Tap anywhere here to measure. Use one hand and keep your body still.")
                        Text("Using your \(model.selectedHand) hand. Swipe left for left hand, right for right hand.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.calibrating ? "Stop measurement" : "Measure comfortable reach")
                .accessibilityHint("VoiceOver two-finger double tap also starts or stops measurement. Successful measurement closes setup automatically.")
                .accessibilityIdentifier("reach.calibrate")
                .simultaneousGesture(DragGesture(minimumDistance: 60).onEnded { value in
                    guard !model.calibrating, abs(value.translation.width) > abs(value.translation.height) else { return }
                    model.chooseReachHand(value.translation.width < 0 ? "left" : "right")
                })
                HStack {
                    Button("Left hand") { model.chooseReachHand("left") }
                    Button("Right hand") { model.chooseReachHand("right") }
                }
                .disabled(model.calibrating)
                Button("Repeat spoken instructions") { model.explainSetup() }
                    .frame(minHeight: 60)
            }
            .padding(24)
        }
        .accessibilityAction(.magicTap) { activate() }
        .accessibilityAction(.escape) { close() }
        .accessibilityAction(named: "Stop") { model.stop() }
        .accessibilityAction(named: "Use left hand") { model.chooseReachHand("left") }
        .accessibilityAction(named: "Use right hand") { model.chooseReachHand("right") }
        .onLongPressGesture(minimumDuration: 0.8) { close() }
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
