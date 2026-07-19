import SwiftUI

/// Crop, rotation, straightening, and flips.
struct GeometryPanel: View {
    @Bindable var model: EditorModel

    private var geometry: Geometry { model.editStack.geometry }

    /// Common crop ratios. `nil` means the original frame.
    private static let aspectRatios: [(String, Double?)] = [
        ("Original", nil), ("1:1", 1), ("4:5", 4.0 / 5), ("3:2", 3.0 / 2),
        ("2:3", 2.0 / 3), ("16:9", 16.0 / 9),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    model.editStack.geometry.rotation = geometry.rotation.previous
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                Button {
                    model.editStack.geometry.rotation = geometry.rotation.next
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                Button {
                    model.editStack.geometry.flipHorizontal.toggle()
                } label: {
                    Label("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                Button {
                    model.editStack.geometry.flipVertical.toggle()
                } label: {
                    Label("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)

            AdjustmentSlider(title: "Straighten",
                             value: $model.editStack.geometry.straightenAngle,
                             range: -45...45, format: "%.1f°", neutral: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text("Aspect Ratio")
                    .font(.subheadline)
                HStack(spacing: 6) {
                    ForEach(Self.aspectRatios, id: \.0) { label, ratio in
                        Button(label) { model.setCropAspectRatio(ratio) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
            }

            if !geometry.isIdentity {
                Button("Reset Crop & Rotation") {
                    model.editStack.geometry = Geometry()
                }
                .controlSize(.small)
            }
        }
    }
}
