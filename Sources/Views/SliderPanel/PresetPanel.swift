import SwiftUI

/// Saved develop presets, and the read-only capture metadata panel.
struct PresetPanel: View {
    @Bindable var app: AppModel
    @Bindable var model: EditorModel

    @State private var isNaming = false
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.presets.isEmpty {
                Text("No presets yet. Develop a frame, then save its look to "
                     + "apply across the roll.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(groupedPresets, id: \.0) { group, presets in
                    Text(group.uppercased())
                        .engraved()
                    ForEach(presets) { preset in
                        PresetRow(preset: preset, app: app, model: model)
                    }
                }
            }

            PlateButton(title: "Save Current as Preset") {
                presetName = ""
                isNaming = true
            }
            .padding(.top, 4)

            Text("A preset carries the look, not the crop or this scan's film "
                 + "base — those belong to the individual frame.")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
        .alert("Save Preset", isPresented: $isNaming) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                app.savePreset(named: name, from: model.editStack)
            }
        }
    }

    private var groupedPresets: [(String, [DevelopPreset])] {
        Dictionary(grouping: app.presets, by: \.group)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }
}

private struct PresetRow: View {
    let preset: DevelopPreset
    @Bindable var app: AppModel
    @Bindable var model: EditorModel

    @State private var isHovering = false

    var body: some View {
        HStack {
            Button {
                model.applyPreset(preset)
            } label: {
                Text(preset.name)
                    .font(Theme.controlFont)
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if isHovering {
                GlyphButton(kind: .cross, label: "Delete preset") {
                    app.deletePreset(preset)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 3)
                .fill(isHovering ? Theme.control.opacity(0.6) : .clear)
        }
        .onHover { isHovering = $0 }
    }
}

/// Read-only capture metadata for the open photo.
struct MetadataPanel: View {
    let metadata: PhotoMetadata
    let fileName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("File", fileName)
            if let dimensions = metadata.dimensions { row("Size", dimensions) }
            if let camera = metadata.camera { row("Camera", camera) }
            if let lens = metadata.lensModel { row("Lens", lens) }
            if let focal = metadata.focalLengthDescription { row("Focal", focal) }
            if let aperture = metadata.apertureDescription { row("Aperture", aperture) }
            if let shutter = metadata.shutterDescription { row("Shutter", shutter) }
            if let iso = metadata.iso { row("ISO", "\(iso)") }
            if let profile = metadata.colorProfile { row("Profile", profile) }
            if let date = metadata.captureDate {
                row("Captured", date.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(.system(size: 9.5, design: .monospaced))
                .kerning(0.8)
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
}
