// labels: production, needs-review
// G3 screen: scan, place marker, save map; after relaunch, load map and time relocalization.

import ARKit
import RealityKit
import SwiftUI

struct G3MeasureView: View {
    @State private var model = G3Model()

    var body: some View {
        ZStack(alignment: .bottom) {
            G3ARContainer(model: model).ignoresSafeArea()
            Image(systemName: "plus").font(.title).foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            panel
        }
        .onAppear { model.startFresh() }
        .onDisappear { model.pause() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.status).font(.headline)
            Text("tracking \(model.tracking)  mapping \(model.mapping)  marker \(model.marker == nil ? "none" : "shown")")
            HStack {
                Button("Place marker") { model.placeMarker() }
                Button("Save map") { model.saveMap() }
                    .disabled(model.marker == nil || !(model.mapping == "mapped" || model.mapping == "extending"))
                Button("Load map") { model.loadMap() }
                    .disabled(!model.hasSavedMap || model.loading)
            }
            .buttonStyle(.borderedProminent)
            HStack {
                Button("New scan") { model.startFresh() }.buttonStyle(.bordered)
                Spacer()
                if let url = model.csvURL { ShareLink("CSV", item: url).buttonStyle(.borderedProminent) }
            }
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
    }
}

private struct G3ARContainer: UIViewRepresentable {
    let model: G3Model

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = model.session
        let root = AnchorEntity(world: .zero)
        root.addChild(context.coordinator.dot)
        view.scene.addAnchor(root)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.dot.isEnabled = model.marker != nil
        if let p = model.marker { context.coordinator.dot.position = p }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.01), materials: [UnlitMaterial(color: .green)])
    }
}
