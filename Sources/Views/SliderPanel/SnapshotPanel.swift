import SwiftUI

/// Named saved states of this photo's edit stack: keep a version, try
/// something else, come back.
struct SnapshotPanel: View {
    @Bindable var model: EditorModel

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            HStack(spacing: 8) {
                TextField("", text: $name,
                          prompt: Text("name this state…")
                            .font(Theme.controlFont)
                            .foregroundStyle(Theme.tertiaryText))
                    .textFieldStyle(.plain)
                    .font(Theme.controlFont)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.control.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .stroke(Theme.separator, lineWidth: Theme.hairline))
                    .onSubmit(save)

                PlateButton(title: "Save") { save() }
            }

            if model.snapshots.isEmpty {
                Text("A snapshot keeps this exact look while you try another "
                     + "direction. Restoring one is undoable.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.snapshots) { snapshot in
                        SnapshotRow(snapshot: snapshot, model: model)
                    }
                }
            }
        }
    }

    private func save() {
        model.saveSnapshot(named: name)
        name = ""
    }
}

private struct SnapshotRow: View {
    let snapshot: EditSnapshot
    @Bindable var model: EditorModel

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.applySnapshot(snapshot)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.name)
                        .font(Theme.controlFont)
                        .foregroundStyle(Theme.text.opacity(0.9))
                    Text(snapshot.dateCreated.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore this state")

            Spacer()

            if isHovering {
                GlyphButton(kind: .cross, label: "Delete snapshot") {
                    model.deleteSnapshot(snapshot)
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
