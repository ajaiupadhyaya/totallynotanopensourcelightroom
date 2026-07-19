import SwiftUI

/// The film-negative section of the adjustment panel: turn conversion on,
/// sample the film base, pick or calibrate a stock, and place the exposure.
struct FilmPanel: View {
    @Bindable var model: EditorModel

    @State private var isShowingCalibration = false

    private var film: FilmNegativeSettings { model.editStack.filmNegative }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            LampToggle(label: "Negative Conversion", isOn: Binding(
                get: { model.editStack.filmNegative.isEnabled },
                set: { isOn in
                    if isOn {
                        model.enableFilmNegative()
                    } else {
                        model.editStack.filmNegative.isEnabled = false
                    }
                }
            ))

            if film.isEnabled {
                TabStrip(
                    options: [
                        (FilmType.colorNegative, "C-41"),
                        (.blackAndWhiteNegative, "B&W"),
                        (.slide, "Slide"),
                    ],
                    selection: $model.editStack.filmNegative.type
                )

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
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(film.baseColor.cgColor))
                    .frame(width: 26, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .stroke(Theme.separator, lineWidth: Theme.hairline))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Film Base")
                        .font(Theme.controlFont)
                    Text(model.hasSampledBase ? "sampled from this scan" : "assumed default")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(model.hasSampledBase
                                         ? AnyShapeStyle(Theme.secondaryText)
                                         : AnyShapeStyle(Theme.filmEdge))
                }

                Spacer()

                PlateButton(title: "Auto") { model.sampleFilmBase() }

                PlateButton(title: model.canvasPicker == .filmBase ? "Click…" : "Pick") {
                    model.canvasPicker = model.canvasPicker == .filmBase ? nil : .filmBase
                }
            }

            Text("Sampling reads the brightest area, which on a negative is "
                 + "the unexposed film base. Include some clear border in the "
                 + "scan for the best result.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: Stock selection

    private var stockControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("STOCK")
                    .engraved()
                Spacer()
                PlateButton(title: "Calibrate") { isShowingCalibration = true }
            }

            // The stock list is long and grouped, which is exactly what a
            // menu is for; only its closed face is drawn here.
            Menu {
                ForEach(stockGroups, id: \.0) { group, stocks in
                    Section(group) {
                        ForEach(stocks) { stock in
                            Button(stock.displayName) { model.applyFilmStock(stock) }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(film.stockName ?? "None")
                        .font(Theme.controlFont)
                        .foregroundStyle(Theme.text.opacity(0.9))
                    Spacer()
                    Glyph(kind: .chevronDown, size: 6, weight: 1.1)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.control.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.separator, lineWidth: Theme.hairline))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)

            if !model.stockMatches.isEmpty {
                matchList
            }
        }
    }

    private var matchList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CLOSEST TO THIS SCAN'S BASE")
                .engraved()

            ForEach(model.stockMatches.prefix(3)) { match in
                Button {
                    model.applyFilmStock(match.stock)
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(match.stock.baseColor.cgColor))
                            .frame(width: 14, height: 14)
                        Text(match.stock.displayName)
                            .font(.system(size: 10, design: .monospaced))
                        Spacer()
                        Text("\(Int(match.confidence * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Be straight with the user about what this ranking is worth.
            Text("Base color separates color negative from B&W or slide "
                 + "reliably, but most C-41 stocks share a near-identical mask — "
                 + "so treat these as candidates, not an identification. For "
                 + "accuracy, pick the stock you actually shot and calibrate it.")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 2)
        }
        .padding(8)
        .background(Theme.control.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
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
            Text("CALIBRATE FILM STOCK")
                .engraved()
            Text("Saves this scan's film base and character as a profile you "
                 + "can apply to the rest of the roll.")
                .font(Theme.controlFont)
                .foregroundStyle(Theme.secondaryText)

            VStack(spacing: 8) {
                field("Manufacturer", text: $manufacturer, prompt: "Kodak")
                field("Stock name", text: $name, prompt: "Portra 400")
                field("ISO", text: $isoText, prompt: "400")
            }

            HStack {
                Spacer()
                PlateButton(title: "Cancel") { dismiss() }
                PlateButton(title: "Save",
                            isEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                    model.saveCalibratedStock(
                        name: name.trimmingCharacters(in: .whitespaces),
                        manufacturer: manufacturer.trimmingCharacters(in: .whitespaces),
                        iso: Int(isoText)
                    )
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.surface)
        .foregroundStyle(Theme.text)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 10) {
            Text(label.uppercased())
                .font(Theme.plateFont)
                .kerning(Theme.plateTracking)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 110, alignment: .leading)
            TextField("", text: text,
                      prompt: Text(prompt)
                        .font(Theme.controlFont)
                        .foregroundStyle(Theme.tertiaryText))
                .textFieldStyle(.plain)
                .font(Theme.controlFont)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.control.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.separator, lineWidth: Theme.hairline))
        }
    }
}
