// labels: production, needs-review
// G2 screen: lock a SAM target, walk around, re-measure. Green dot = first lock (should stay on
// the object while you move), blue dot = latest re-measure.

import ARKit
import RealityKit
import SightlineCore
import SwiftUI

struct G2MeasureView: View {
    @State private var model = G2Model()

    var body: some View {
        ZStack(alignment: .bottom) {
            G2ARContainer(model: model).ignoresSafeArea()
            panel
        }
        .onAppear { model.configure() }
        .onDisappear { model.pause() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.status).font(.headline)
            if !model.hasKey {
                Text("No API key in this build. Run tools/ios_secrets.sh on the Mac, then rebuild.")
                    .foregroundStyle(.red)
            }
            Text("tracking \(model.tracking)  SAM calls left \(model.callsLeft)/\(G2Model.maxCalls)")
            HStack {
                TextField("Object", text: $model.noun)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(model.firstTarget != nil)
                Button(model.firstTarget == nil ? "Lock" : "Re-measure") { model.measure() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.callsLeft == 0 || !model.hasKey || model.noun.isEmpty)
                if let url = model.csvURL {
                    ShareLink("CSV", item: url).buttonStyle(.borderedProminent)
                }
            }
            Divider()
            ForEach(model.rows.suffix(5), id: \.index) { row in
                Text(line(row))
            }
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
    }

    private func line(_ r: G2Row) -> String {
        guard r.failReason.isEmpty else { return "#\(r.index) failed: \(r.failReason)" }
        return String(format: "#%d  %@  c %.2f  range %.2f m  spread %.1f cm  Δfirst %.1f cm  %.1f s",
                      r.index, r.chosenID ?? "-", r.confidence ?? 0, r.cameraToTarget ?? 0,
                      (r.depthSpread ?? 0) * 100, (r.distanceToFirst ?? 0) * 100, r.elapsed ?? 0)
    }
}

private struct G2ARContainer: UIViewRepresentable {
    let model: G2Model

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = model.session
        view.renderOptions.insert(.disableMotionBlur)
        let root = AnchorEntity(world: .zero)
        root.addChild(context.coordinator.firstDot)
        root.addChild(context.coordinator.latestDot)
        view.scene.addAnchor(root)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.place(context.coordinator.firstDot, at: model.firstTarget)
        context.coordinator.place(context.coordinator.latestDot, at: model.rows.count > 1 ? model.latestTarget : nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let firstDot = Coordinator.dot(.green, radius: 0.008)
        let latestDot = Coordinator.dot(.systemBlue, radius: 0.006)

        static func dot(_ color: UIColor, radius: Float) -> ModelEntity {
            ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: color)])
        }

        func place(_ dot: ModelEntity, at position: SIMD3<Float>?) {
            dot.isEnabled = position != nil
            if let position { dot.position = position }
        }
    }
}
