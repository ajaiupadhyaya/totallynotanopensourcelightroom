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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupedPresets, id: \.0) { group, presets in
                    Text(group.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(presets) { preset in
                        HStack {
                            Button(preset.name) { model.applyPreset(preset) }
                                .buttonStyle(.plain)
                            Spacer()
                            Button {
                                app.deletePreset(preset)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            }

            Button("Save Current as Preset…") {
                presetName = ""
                isNaming = true
            }
            .controlSize(.small)
            .padding(.top, 4)

            Text("A preset carries the look, not the crop or this scan's film "
                 + "base — those belong to the individual frame.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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

/// Read-only capture metadata for the open photo.
struct MetadataPanel: View {
    let metadata: PhotoMetadata
    let fileName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("File", fileName)
            if let dimensions = metadata.dimensions { row("Dimensions", dimensions) }
            if let camera = metadata.camera { row("Camera", camera) }
            if let lens = metadata.lensModel { row("Lens", lens) }
            if let focal = metadata.focalLengthDescription { row("Focal Length", focal) }
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
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
}
