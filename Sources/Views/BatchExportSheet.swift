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
        VStack(alignment: .leading, spacing: 16) {
            Text(entries.count == 1
                 ? "EXPORT PHOTO"
                 : "EXPORT \(entries.count) PHOTOS")
                .engraved()

            VStack(alignment: .leading, spacing: 14) {
                labeled("Format") {
                    TabStrip(
                        options: ExportSettings.Format.allCases.map { ($0, $0.displayName) },
                        selection: $settings.format
                    )
                }

                if settings.format.supportsQuality {
                    AdjustmentSlider(title: "Quality",
                                     value: Binding(
                                        get: { settings.quality * 100 },
                                        set: { settings.quality = $0 / 100 }
                                     ),
                                     range: 10...100, format: "%.0f%%", neutral: 90)
                }

                labeled("Profile") {
                    TabStrip(
                        options: ExportSettings.ColorProfile.allCases.map { ($0, $0.displayName) },
                        selection: $settings.colorProfile
                    )
                }

                labeled("Sharpen") {
                    TabStrip(
                        options: ExportSettings.OutputSharpening.allCases.map {
                            ($0, $0 == .web ? "Web" : $0.displayName)
                        },
                        selection: $settings.outputSharpening
                    )
                }

                LampToggle(label: "Limit long edge", isOn: $limitSize)
                if limitSize {
                    AdjustmentSlider(title: "Long Edge",
                                     value: $maxDimension,
                                     range: 640...8192, format: "%.0f px", neutral: 2048)
                }
            }

            if let progress = app.exportProgress {
                VStack(alignment: .leading, spacing: 4) {
                    // A drawn progress bar: hairline case, quiet fill.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.control)
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(width: geo.size.width
                                       * CGFloat(progress.completed)
                                       / CGFloat(max(progress.total, 1)))
                        }
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                    Text("Exporting \(progress.completed) of \(progress.total)…")
                        .font(Theme.valueFont)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            if let result {
                resultSummary(result)
            }

            HStack {
                Text("Each photo renders from its full-resolution original.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                PlateButton(title: result == nil ? "Cancel" : "Done") { dismiss() }
                PlateButton(title: "Choose Folder",
                            isEnabled: !entries.isEmpty && !app.isExporting) {
                    presentPanel()
                }
            }
        }
        .padding(20)
        .frame(width: 470)
        .background(Theme.surface)
        .foregroundStyle(Theme.text)
        .background {
            Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0)
        }
    }

    private func labeled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(Theme.plateFont)
                .kerning(Theme.plateTracking)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// Reports partial success honestly rather than claiming everything worked.
    @ViewBuilder
    private func resultSummary(_ result: BatchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.failures.isEmpty
                 ? "EXPORTED \(result.written) OF \(entries.count)"
                 : "EXPORTED \(result.written) OF \(entries.count) — \(result.failures.count) FAILED")
                .font(Theme.plateFont)
                .kerning(Theme.plateTracking)
                .foregroundStyle(result.failures.isEmpty
                                 ? AnyShapeStyle(Theme.text)
                                 : AnyShapeStyle(Color.orange))

            ForEach(result.failures.prefix(4), id: \.entry.id) { failure in
                Text("\(failure.entry.fileName): \(failure.error.localizedDescription)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            if result.failures.count > 4 {
                Text("…and \(result.failures.count - 4) more.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.control.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
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
