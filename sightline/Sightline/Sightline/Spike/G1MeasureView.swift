// labels: production, needs-review
// G1 screen: camera view with a green dot on the reference centre and a red dot on the
// estimated fingertip (visual check of the 2D -> 3D pipeline), live numbers, CSV export.

import ARKit
import RealityKit
import SightlineCore
import SwiftUI

struct G1MeasureView: View {
    @State private var model = G1Model()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainer(model: model).ignoresSafeArea()
            panel
        }
        .onAppear { model.configureSession() }
        .onDisappear { model.pause() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.statusLine).font(.headline)
            live
            Divider()
            controls
            Divider()
            reports
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
    }

    private var live: some View {
        let m = model.latest
        let distance: String = {
            guard let tip = m?.tip, let ref = m?.reference else { return "-" }
            return String(format: "%.1f cm", simd_distance(tip, ref) * 100)
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text("tracking \(m?.tracking ?? "-")  marker \(m?.reference == nil ? "not seen" : "tracked")  jitter \(m?.referenceJitterMM.map { String(format: "%.1f mm", $0) } ?? "-")")
            Text("hand \(m?.handConfidence.map { String(format: "%.2f", $0) } ?? "-")  depth \(m?.tipDepth.map { String(format: "%.3f m", $0) } ?? "-")  samples \(m?.validSamples ?? 0)\(m?.depthRelaxed == true ? " relaxed" : "")")
            Text("tip→ref \(distance)  \(m?.failReason ?? "ok")")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Distance", selection: $model.distanceCM) {
                    ForEach([30, 50, 70], id: \.self) { Text("\($0) cm") }
                }
                .pickerStyle(.segmented)
                Picker("Angle", selection: $model.angleDeg) {
                    ForEach([0, 45], id: \.self) { Text("\($0)°") }
                }
                .pickerStyle(.segmented)
            }
            .disabled(model.phase == .capturing || model.phase == .checkingJitter)
            Stepper(value: $model.markerWidthMM, in: 80...120, step: 0.5) {
                Text(String(format: "Measured marker width %.1f mm", model.markerWidthMM))
            }
            HStack {
                if model.phase == .capturing || model.phase == .checkingJitter {
                    Button("Stop", role: .destructive) { model.stopScenario() }
                } else {
                    Button("Start \(model.scenario)") { model.startScenario() }
                }
                Spacer()
                Text("\(model.touchesInScenario)/\(G1Model.touchesPerScenario) touches")
                if let url = model.csvURL {
                    ShareLink("CSV", item: url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var reports: some View {
        VStack(alignment: .leading, spacing: 2) {
            reportLine("this", model.report(for: model.scenario))
            reportLine("all ", model.report(for: nil))
        }
    }

    private func reportLine(_ label: String, _ r: AccuracyReport) -> some View {
        func cm(_ v: Float?) -> String { v.map { String(format: "%.1f", $0 * 100) } ?? "-" }
        let gate = r.touches == 0 ? "" : (r.passesGate ? "PASS" : "not yet")
        return Text("\(label) n=\(r.touches) med \(cm(r.median)) mean \(cm(r.mean)) p90 \(cm(r.p90)) cm  valid \(Int(r.validRate * 100))%  \(gate)")
    }
}

/// RealityKit view sharing the model's ARSession; draws the two marker dots.
private struct ARContainer: UIViewRepresentable {
    let model: G1Model

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = model.session
        view.renderOptions.insert(.disableMotionBlur)
        let root = AnchorEntity(world: .zero)
        root.addChild(context.coordinator.referenceDot)
        root.addChild(context.coordinator.tipDot)
        view.scene.addAnchor(root)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let m = model.latest
        context.coordinator.place(context.coordinator.referenceDot, at: m?.reference)
        context.coordinator.place(context.coordinator.tipDot, at: m?.tip)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let referenceDot = Coordinator.dot(.green)
        let tipDot = Coordinator.dot(.red)

        static func dot(_ color: UIColor) -> ModelEntity {
            ModelEntity(mesh: .generateSphere(radius: 0.004), materials: [UnlitMaterial(color: color)])
        }

        func place(_ dot: ModelEntity, at position: SIMD3<Float>?) {
            dot.isEnabled = position != nil
            if let position { dot.position = position }
        }
    }
}
