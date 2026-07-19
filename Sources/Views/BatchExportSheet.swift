import AppKit
import SwiftUI

/// Exports a set of photos to a chosen folder, each rendered from its own
/// full-resolution original.
struct BatchExportSheet: View {
    @Bindable var app: AppModel
    let entries: [CatalogEntry]

    @Environment(\.dismiss) private var dismiss

    @State private var settings = ExportSettings()
    @State private var limitSize = false
    @State private var maxDimension = 2048.0
    @State private var result: BatchResult?

    private struct BatchResult {
        let written: Int
        let failures: [(entry: CatalogEntry, error: Error)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(entries.count == 1 ? "Export Photo" : "Export \(entries.count) Photos")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Format", selection: $settings.format) {
                    ForEach(ExportSettings.Format.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                if settings.format.supportsQuality {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $settings.quality, in: 0.1...1.0) { Text("Quality") }
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

                Picker("Output Sharpening", selection: $settings.outputSharpening) {
                    ForEach(ExportSettings.OutputSharpening.allCases) { option in
                        Text(option.displayName).tag(option)
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

            if let progress = app.exportProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress.completed),
                                 total: Double(max(progress.total, 1)))
                    Text("Exporting \(progress.completed) of \(progress.total)…")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let result {
                resultSummary(result)
            }

            HStack {
                Text("Each photo renders from its full-resolution original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Folder…") { presentPanel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entries.isEmpty || app.isExporting)
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    /// Reports partial success honestly rather than claiming everything worked.
    @ViewBuilder
    private func resultSummary(_ result: BatchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Exported \(result.written) of \(entries.count)",
                  systemImage: result.failures.isEmpty
                    ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(result.failures.isEmpty
                                 ? AnyShapeStyle(.green) : AnyShapeStyle(Color.orange))

            ForEach(result.failures.prefix(4), id: \.entry.id) { failure in
                Text("\(failure.entry.fileName): \(failure.error.localizedDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if result.failures.count > 4 {
                Text("…and \(result.failures.count - 4) more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func presentPanel() {
        var resolved = settings
        resolved.maxDimension = limitSize ? maxDimension : nil

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        Task {
            let outcome = await app.batchExport(entries, settings: resolved, to: directory)
            result = BatchResult(written: outcome.written.count, failures: outcome.failures)
        }
    }
}
