import SwiftUI

/// Crop, rotation, straightening, and flips.
struct GeometryPanel: View {
    @Bindable var model: EditorModel

    private var geometry: Geometry { model.editStack.geometry }

    /// Common crop ratios. `nil` means the original frame.
    private static let aspectRatios: [(String, Double?)] = [
        ("Orig", nil), ("1:1", 1), ("4:5", 4.0 / 5), ("3:2", 3.0 / 2),
        ("2:3", 2.0 / 3), ("16:9", 16.0 / 9),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            // Quarter turns and mirrors, named plainly.
            HStack(spacing: 6) {
                PlateButton(title: "⟲ 90") {
                    model.editStack.geometry.rotation = geometry.rotation.previous
                }
                PlateButton(title: "⟳ 90") {
                    model.editStack.geometry.rotation = geometry.rotation.next
                }
                PlateButton(title: "Flip H") {
                    model.editStack.geometry.flipHorizontal.toggle()
                }
                PlateButton(title: "Flip V") {
                    model.editStack.geometry.flipVertical.toggle()
                }
            }

            AdjustmentSlider(title: "Straighten",
                             value: $model.editStack.geometry.straightenAngle,
                             range: -45...45, format: "%.1f°", neutral: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text("RATIO")
                    .engraved()
                HStack(spacing: 6) {
                    ForEach(Self.aspectRatios, id: \.0) { label, ratio in
                        PlateButton(title: label) { model.setCropAspectRatio(ratio) }
                    }
                }
            }

            PlateButton(title: model.isCropping ? "Recomposing…" : "Recompose on Canvas",
                        isEnabled: !model.isCropping,
                        fillsWidth: true) {
                model.enterCropMode()
            }
        }
    }
}
