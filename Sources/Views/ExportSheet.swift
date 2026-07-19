import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export options for the open photo, plus the save panel that writes it.
///
/// Everything here operates on the full-resolution original — the preview on
/// screen is only a proxy.
struct ExportSheet: View {
    @Bindable var editor: EditorModel

    @Environment(\.dismiss) private var dismiss

    @State private var settings = ExportSettings()
    @State private var limitSize = false
    @State private var maxDimension = 2048.0
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Photo")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Format", selection: $settings.format) {
                    ForEach(ExportSettings.Format.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                if settings.format.supportsQuality {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $settings.quality, in: 0.1...1.0) {
                            Text("Quality")
                        }
                        Text("\(Int(settings.quality * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Color Profile", selection: $settings.colorProfile) {
                    ForEach(ExportSettings.ColorProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }

                Toggle("Limit long edge", isOn: $limitSize)
                if limitSize {
                    HStack {
                        Slider(value: $maxDimension, in: 640...8192, step: 64)
                        Text("\(Int(maxDimension)) px")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("Renders from the full-resolution original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { presentSavePanel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func presentSavePanel() {
        var resolved = settings
        resolved.maxDimension = limitSize ? maxDimension : nil

        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportService.suggestedFileName(
            for: editor.entry.fileURL, settings: resolved
        )
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: resolved.format.fileExtension) {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        errorMessage = nil
        do {
            try editor.export(settings: resolved, to: url)
            isExporting = false
            dismiss()
        } catch {
            isExporting = false
            errorMessage = error.localizedDescription
        }
    }
}
