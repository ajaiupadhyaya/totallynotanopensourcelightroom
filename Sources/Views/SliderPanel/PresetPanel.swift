import SwiftUI

/// Saved develop presets, and the read-only capture metadata panel.
struct PresetPanel: View {
    @Bindable var app: AppModel
    @Bindable var model: EditorModel

    @State private var isNaming = false
    @State private var presetName = ""
    @State private var presetGroup = ""

    /// How much of the hovered/clicked preset to apply, as a percentage. View
    /// state: an amount is a decision about *this* application, not a property
    /// of the preset.
    @State private var presetAmount = 100.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.presets.isEmpty {
                Text("No presets yet. Develop a frame, then save its look to "
                     + "apply across the roll.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                AdjustmentSlider(title: "Amount", value: $presetAmount,
                                 range: 0...100, format: "%.0f", neutral: 100)

                ForEach(groupedPresets, id: \.key) { group in
                    if group.showsRoot {
                        Text(group.path[0].uppercased())
                            .sectionLabel()
                    }
                    if group.path.count > 1 {
                        // Nesting is typography, not chrome: a quieter,
                        // indented label rather than a disclosure widget.
                        Text(group.path.dropFirst().joined(separator: " / "))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.leading, Theme.space3)
                    }
                    ForEach(group.presets) { preset in
                        PresetRow(preset: preset, app: app, model: model,
                                  amount: presetAmount)
                            .padding(.leading, group.path.count > 1 ? Theme.space3 : 0)
                    }
                }
            }

            PlateButton(title: "Save Current as Preset") {
                presetName = ""
                presetGroup = ""
                isNaming = true
            }
            .padding(.top, 4)

            HStack(spacing: Theme.space2) {
                PlateButton(title: "Import…") { app.importPresets() }
                PlateButton(title: "Export All…", isEnabled: !app.presets.isEmpty) {
                    app.exportPresets()
                }
            }

            Text("A preset carries the look, not the crop or this scan's film "
                 + "base — those belong to the individual frame.")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
        .sheet(isPresented: $isNaming) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                Text("SAVE PRESET").sectionLabel(Theme.text)
                InstrumentField(placeholder: "Preset name", text: $presetName)
                InstrumentField(placeholder: "Folder  (use / to nest)", text: $presetGroup)
                HStack {
                    Spacer()
                    PlateButton(title: "Cancel") { isNaming = false }
                    PlateButton(title: "Save", emphasis: .prominent) {
                        let name = presetName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        let folder = presetGroup.trimmingCharacters(in: .whitespaces)
                        app.savePreset(named: name, from: model.editStack,
                                       group: folder.isEmpty ? "User Presets" : folder)
                        isNaming = false
                    }
                }
            }
            .padding(Theme.space5)
            .frame(width: 320)
            .background(Theme.surface)
        }
    }

    /// Presets grouped by their parsed folder path, sorted by path then name.
    /// `showsRoot` marks the first group of each top-level folder, so the
    /// heading is printed once rather than over every nested group.
    private var groupedPresets: [(key: String, path: [String],
                                  presets: [DevelopPreset], showsRoot: Bool)] {
        let groups = Dictionary(grouping: app.presets) { $0.folderPath.joined(separator: "/") }
            .map { (key: $0.key,
                    path: $0.value[0].folderPath,
                    presets: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.key < $1.key }
        var lastRoot: String?
        return groups.map { group in
            let showsRoot = group.path.first != lastRoot
            lastRoot = group.path.first
            return (group.key, group.path, group.presets, showsRoot)
        }
    }
}

private struct PresetRow: View {
    let preset: DevelopPreset
    @Bindable var app: AppModel
    @Bindable var model: EditorModel
    /// Percent of the preset to apply — the panel's Amount slider.
    let amount: Double

    @State private var isHovering = false

    var body: some View {
        HStack {
            Button {
                model.applyPreset(preset, amount: amount / 100)
            } label: {
                Text(preset.name)
                    .font(Theme.controlLabel)
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if isHovering {
                IconButton(icon: .cross, label: "Delete preset") {
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
        .onHover { hovering in
            isHovering = hovering
            // The canvas answers "what would this look like" directly, on the
            // photograph, without committing anything.
            if hovering {
                model.beginPresetPreview(preset, amount: amount / 100)
            } else {
                model.endPresetPreview(preset)
            }
        }
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
