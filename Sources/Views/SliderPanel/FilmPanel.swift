import SwiftUI

/// The film-negative section of the adjustment panel: turn conversion on,
/// sample the film base, pick or calibrate a stock, and place the exposure.
struct FilmPanel: View {
    @Bindable var model: EditorModel

    @State private var isShowingCalibration = false
    @State private var isShowingTrims = false

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
                if film.conversionModel == .matrix {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This photo uses the original matrix conversion. "
                             + "Updating re-solves it through the print engine — "
                             + "the current look is snapshotted first and stays "
                             + "one click away.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                        PlateButton(title: "Update Conversion") {
                            model.updateConversion()
                        }
                    }
                }

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

                if film.conversionModel == .density && film.type.requiresInversion {
                    printControls
                } else {
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
        }
        .sheet(isPresented: $isShowingCalibration) {
            CalibrateStockSheet(model: model)
        }
    }

    // MARK: Film base

    /// Which measurement the conversion is trusting — the honesty caption.
    private var baseOriginCaption: String {
        switch film.baseOrigin {
        case .assumed: "assumed default"
        case .estimated: "estimated from this scan"
        case .sampled: "sampled from this scan"
        }
    }

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
                        .font(Theme.controlLabel)
                    Text(baseOriginCaption)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(film.baseOrigin == .assumed
                                         ? AnyShapeStyle(Theme.filmEdge)
                                         : AnyShapeStyle(Theme.secondaryText))
                }

                Spacer()

                PlateButton(title: "Auto") {
                    if film.conversionModel == .density {
                        model.autoConvertNegative()
                    } else {
                        model.sampleFilmBase()
                    }
                }

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
                    .sectionLabel()
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
                        .font(Theme.controlLabel)
                        .foregroundStyle(Theme.text.opacity(0.9))
                    Spacer()
                    Icon(kind: .chevronDown, size: 9, weight: 1.3)
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
                .sectionLabel()

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

    /// The print engine's front controls — the terms a printer would use.
    private var printControls: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            AdjustmentSlider(title: "Print Exposure",
                             value: $model.editStack.filmNegative.print.exposure,
                             range: -3...3, format: "%.2f EV", neutral: 0)
            AdjustmentSlider(title: "Print Contrast",
                             value: $model.editStack.filmNegative.print.contrast,
                             range: 0...5, format: "Grade %.1f", neutral: 2)
            AdjustmentSlider(title: "Shoulder",
                             value: $model.editStack.filmNegative.print.shoulder,
                             range: 0...100, format: "%.0f", neutral: 40)
            AdjustmentSlider(title: "Toe",
                             value: $model.editStack.filmNegative.print.toe,
                             range: 0...100, format: "%.0f", neutral: 30)
            if film.type != .blackAndWhiteNegative {
                AdjustmentSlider(title: "Print Saturation",
                                 value: $model.editStack.filmNegative.print.saturation,
                                 range: -50...50, format: "%.0f", neutral: 12)
                // Filtration is a color cast; on B&W the mono clamp after the
                // kernel (below) strips it, so it would move nothing. Same
                // gate as Print Saturation, same reason.
                AdjustmentSlider(title: "Print Warmth",
                                 value: $model.editStack.filmNegative.print.warmth,
                                 range: -100...100, format: "%.0f", neutral: 0)
                AdjustmentSlider(title: "Print Tint",
                                 value: $model.editStack.filmNegative.print.tint,
                                 range: -100...100, format: "%.0f", neutral: 0)
            }

            PlateButton(title: isShowingTrims ? "Hide Per-Channel" : "Per-Channel…") {
                isShowingTrims.toggle()
            }
            if isShowingTrims { channelTrims }
        }
    }

    /// The crossover controls. Behind a disclosure because nobody wants to
    /// drive three gammas by hand as a first move — but they are the whole
    /// reason this engine exists, so they are here.
    private var channelTrims: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            Text("BASE (D-MIN)").sectionLabel()
            AdjustmentSlider(title: "Red",
                             value: $model.editStack.filmNegative.baseColor.red,
                             range: 0.05...1, format: "%.3f", neutral: FilmNegativeSettings.defaultColorNegativeBase.red)
            AdjustmentSlider(title: "Green",
                             value: $model.editStack.filmNegative.baseColor.green,
                             range: 0.05...1, format: "%.3f", neutral: FilmNegativeSettings.defaultColorNegativeBase.green)
            AdjustmentSlider(title: "Blue",
                             value: $model.editStack.filmNegative.baseColor.blue,
                             range: 0.05...1, format: "%.3f", neutral: FilmNegativeSettings.defaultColorNegativeBase.blue)

            Text("WHITE POINT (D-MAX)").sectionLabel()
            AdjustmentSlider(title: "Red",
                             value: $model.editStack.filmNegative.print.dmax.red,
                             range: 0.2...4, format: "%.2f", neutral: 2)
            AdjustmentSlider(title: "Green",
                             value: $model.editStack.filmNegative.print.dmax.green,
                             range: 0.2...4, format: "%.2f", neutral: 2)
            AdjustmentSlider(title: "Blue",
                             value: $model.editStack.filmNegative.print.dmax.blue,
                             range: 0.2...4, format: "%.2f", neutral: 2)

            Text("PAPER GAMMA").sectionLabel()
            AdjustmentSlider(title: "Red",
                             value: $model.editStack.filmNegative.print.gamma.red,
                             range: 0.2...3, format: "%.2f", neutral: 1)
            AdjustmentSlider(title: "Green",
                             value: $model.editStack.filmNegative.print.gamma.green,
                             range: 0.2...3, format: "%.2f", neutral: 1)
            AdjustmentSlider(title: "Blue",
                             value: $model.editStack.filmNegative.print.gamma.blue,
                             range: 0.2...3, format: "%.2f", neutral: 1)
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
                .sectionLabel()
            Text("Saves this scan's film base and character as a profile you "
                 + "can apply to the rest of the roll.")
                .font(Theme.controlLabel)
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
                        .font(Theme.controlLabel)
                        .foregroundStyle(Theme.tertiaryText))
                .textFieldStyle(.plain)
                .font(Theme.controlLabel)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.control.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.separator, lineWidth: Theme.hairline))
        }
    }
}
