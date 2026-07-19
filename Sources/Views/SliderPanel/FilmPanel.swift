import SwiftUI

/// The film-negative section of the adjustment panel: turn conversion on,
/// sample the film base, pick or calibrate a stock, and place the exposure.
struct FilmPanel: View {
    @Bindable var model: EditorModel

    @State private var isShowingCalibration = false

    private var film: FilmNegativeSettings { model.editStack.filmNegative }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Film Negative", isOn: Binding(
                get: { model.editStack.filmNegative.isEnabled },
                set: { isOn in
                    if isOn {
                        model.enableFilmNegative()
                    } else {
                        model.editStack.filmNegative.isEnabled = false
                    }
                }
            ))
            .font(.subheadline.weight(.medium))

            if film.isEnabled {
                Picker("Film Type", selection: $model.editStack.filmNegative.type) {
                    ForEach(FilmType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                if film.type.requiresInversion {
                    filmBaseControls
                }

                stockControls

                AdjustmentSlider(title: "Film Exposure",
                                 value: $model.editStack.filmNegative.exposure,
                                 range: -3...3, format: "%.2f EV", neutral: 0)

                if film.type != .blackAndWhiteNegative {
                    AdjustmentSlider(title: "Stock Contrast",
                                     value: $model.editStack.filmNegative.stockContrast,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Stock Saturation",
                                     value: $model.editStack.filmNegative.stockSaturation,
                                     range: -100...100, format: "%.0f", neutral: 0)
                }
            }
        }
        .sheet(isPresented: $isShowingCalibration) {
            CalibrateStockSheet(model: model)
        }
    }

    // MARK: Film base

    private var filmBaseControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(film.baseColor.cgColor))
                    .frame(width: 26, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Film Base")
                        .font(.subheadline)
                    Text(model.hasSampledBase ? "Sampled from this scan" : "Assumed default")
                        .font(.caption)
                        .foregroundStyle(model.hasSampledBase
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(Color.orange))
                }

                Spacer()

                Button("Auto") { model.sampleFilmBase() }
                    .controlSize(.small)
                    .help("Sample the brightest area automatically")

                Button {
                    model.canvasPicker = model.canvasPicker == .filmBase ? nil : .filmBase
                } label: {
                    Image(systemName: "eyedropper")
                }
                .controlSize(.small)
                .help("Click a clear piece of film border in the photo")
            }

            Text("Sampling reads the brightest area, which on a negative is the "
                 + "unexposed film base. Include some clear border in the scan "
                 + "for the best result.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Stock selection

    private var stockControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Film Stock")
                    .font(.subheadline)
                Spacer()
                Button("Calibrate…") { isShowingCalibration = true }
                    .controlSize(.small)
            }

            Menu {
                ForEach(stockGroups, id: \.0) { group, stocks in
                    Section(group) {
                        ForEach(stocks) { stock in
                            Button(stock.displayName) { model.applyFilmStock(stock) }
                        }
                    }
                }
            } label: {
                Text(film.stockName ?? "None")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.stockMatches.isEmpty {
                matchList
            }
        }
    }

    private var matchList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Closest to this scan's base")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(model.stockMatches.prefix(3)) { match in
                Button {
                    model.applyFilmStock(match.stock)
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(match.stock.baseColor.cgColor))
                            .frame(width: 14, height: 14)
                        Text(match.stock.displayName)
                            .font(.caption)
                        Spacer()
                        Text("\(Int(match.confidence * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            // Be straight with the user about what this ranking is worth.
            Text("Base color separates color negative from B&W or slide "
                 + "reliably, but most C-41 stocks share a near-identical mask — "
                 + "so treat these as candidates, not an identification. For "
                 + "accuracy, pick the stock you actually shot and calibrate it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Stocks grouped for the menu: calibrated profiles first, then by family.
    private var stockGroups: [(String, [FilmStock])] {
        var groups: [(String, [FilmStock])] = []
        let custom = model.filmStocks.filter(\.isCustom)
        if !custom.isEmpty {
            groups.append(("Calibrated", custom))
        }
        for type in FilmType.allCases {
            let stocks = model.filmStocks.filter { !$0.isCustom && $0.type == type }
            if !stocks.isEmpty {
                groups.append((type.displayName, stocks))
            }
        }
        return groups
    }
}

/// Names the current film settings and saves them as a reusable profile.
private struct CalibrateStockSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var manufacturer = ""
    @State private var isoText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate Film Stock")
                .font(.title3.weight(.semibold))
            Text("Saves this scan's film base and character as a profile you can "
                 + "apply to the rest of the roll.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Manufacturer", text: $manufacturer, prompt: Text("Kodak"))
                TextField("Stock name", text: $name, prompt: Text("Portra 400"))
                TextField("ISO", text: $isoText, prompt: Text("400"))
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveCalibratedStock(
                        name: name.trimmingCharacters(in: .whitespaces),
                        manufacturer: manufacturer.trimmingCharacters(in: .whitespaces),
                        iso: Int(isoText)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
