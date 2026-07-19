import SwiftUI

/// Lens and perspective corrections: manual distortion, keystone, and
/// chromatic-aberration defringe.
struct OpticsPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        AdjustmentSlider(title: "Distortion",
                         value: $model.editStack.geometry.distortion,
                         range: -100...100, format: "%.0f", neutral: 0)
        AdjustmentSlider(title: "Vertical",
                         value: $model.editStack.geometry.perspectiveVertical,
                         range: -100...100, format: "%.0f", neutral: 0)
        AdjustmentSlider(title: "Horizontal",
                         value: $model.editStack.geometry.perspectiveHorizontal,
                         range: -100...100, format: "%.0f", neutral: 0)

        Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

        AdjustmentSlider(title: "Defringe Purple",
                         value: $model.editStack.defringe.purple,
                         range: 0...100, format: "%.0f", neutral: 0)
        AdjustmentSlider(title: "Defringe Green",
                         value: $model.editStack.defringe.green,
                         range: 0...100, format: "%.0f", neutral: 0)

        Text("Defringe desaturates purple or green only along hard edges — "
             + "the only place lens fringing occurs — so subject color is safe.")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
    }
}
