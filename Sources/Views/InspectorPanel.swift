import SwiftUI

/// The right-hand workstation. Adjustments, masks, and history are explicit
/// modes with one shared histogram, matching the selected visual direction and
/// reducing the original inspector's long-scroll ambiguity.
struct InspectorPanel: View {
    @Bindable var model: EditorModel
    @Bindable var app: AppModel
    @Binding var mode: InspectorMode

    var body: some View {
        VStack(spacing: 0) {
            modeBar

            HistogramView(histogram: model.histogram)
                .padding(.horizontal, Theme.panelInset)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ClippingDiagnostics(model: model)
                .padding(.horizontal, Theme.panelInset)
                .padding(.bottom, 11)

            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

            switch mode {
            case .adjust:
                SliderPanel(model: model, app: app)
            case .masks:
                maskWorkspace
            case .history:
                historyWorkspace
            }
        }
        .background(Theme.surface)
    }

    private var modeBar: some View {
        HStack {
            TabStrip(
                options: InspectorMode.allCases.map { ($0, $0.label) },
                selection: $mode
            )
            Spacer()
        }
        .padding(.horizontal, Theme.panelInset)
        .frame(height: Theme.contextBarHeight)
        .background(Theme.background)
    }

    private var maskWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorHeading(index: "M", title: "Local Masks",
                                 detail: "Paint, graduate, and feather corrections directly on the frame.")

                LocalAdjustmentPanel(model: model)

                Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

                Text("REPAIR TOOLS")
                    .engraved()
                RetouchPanel(model: model)
            }
            .padding(Theme.panelInset)
        }
    }

    private var historyWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeading(index: "H", title: "History",
                                 detail: "Every committed state is addressable. Select a row to return to it.")
                    .padding(Theme.panelInset)

                HStack(spacing: 8) {
                    PlateButton(title: "Undo \(model.undoDepth)", isEnabled: model.canUndo) {
                        model.undo()
                    }
                    PlateButton(title: "Redo \(model.redoDepth)", isEnabled: model.canRedo) {
                        model.redo()
                    }
                }
                .padding(.horizontal, Theme.panelInset)
                .padding(.bottom, 12)

                Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

                ForEach(Array(model.historyEvents.reversed().enumerated()), id: \.element.id) {
                    offset, event in
                    let isCurrent = event.stack == model.editStack && offset == 0
                    Button {
                        model.restoreHistoryEvent(event)
                    } label: {
                        HStack(spacing: 10) {
                            Text(String(format: "%02d",
                                        max(model.historyEvents.count - offset - 1, 0)))
                                .font(Theme.indexFont)
                                .foregroundStyle(isCurrent ? Theme.accent : Theme.tertiaryText)
                                .frame(width: 24, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(Theme.readableFont)
                                    .foregroundStyle(isCurrent ? Theme.text
                                                               : Theme.text.opacity(0.78))
                                Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(Theme.valueFont)
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            Spacer()
                            if isCurrent {
                                Text("CURRENT")
                                    .font(Theme.plateFont)
                                    .kerning(Theme.plateTracking)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, Theme.panelInset)
                        .padding(.vertical, 9)
                        .background(isCurrent ? Theme.raisedSurface : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle().fill(Theme.separator.opacity(0.75))
                        .frame(height: Theme.hairline)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("NAMED STATES").engraved()
                    SnapshotPanel(model: model)
                }
                .padding(Theme.panelInset)
            }
        }
    }
}

private struct ClippingDiagnostics: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("CLIPPING").engraved()
                Spacer()
                Text("VIEW AID")
                    .font(Theme.plateFont)
                    .kerning(Theme.plateTracking)
                    .foregroundStyle(Theme.tertiaryText)
            }

            HStack(spacing: 12) {
                diagnosticToggle(
                    "SHADOWS",
                    fraction: model.histogram.shadowClippedFraction,
                    isClipping: model.histogram.isClippingShadows,
                    isOn: $model.showsShadowClipping
                )
                diagnosticToggle(
                    "HIGHLIGHTS",
                    fraction: model.histogram.highlightClippedFraction,
                    isClipping: model.histogram.isClippingHighlights,
                    isOn: $model.showsHighlightClipping
                )
            }
        }
    }

    private func diagnosticToggle(
        _ label: String, fraction: Double, isClipping: Bool, isOn: Binding<Bool>
    ) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isClipping ? "exclamationmark.triangle.fill" : "triangle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isClipping ? Theme.warning : Theme.tertiaryText)
                Text(label)
                    .font(Theme.plateFont)
                    .kerning(Theme.plateTracking)
                Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                    .font(Theme.valueFont)
                    .foregroundStyle(isClipping ? Theme.warning : Theme.secondaryText)
            }
            .foregroundStyle(isOn.wrappedValue ? Theme.text : Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isOn.wrappedValue ? Theme.control : .clear)
            .overlay(Rectangle().stroke(isOn.wrappedValue ? Theme.strongSeparator
                                                          : Theme.separator,
                                        lineWidth: Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

private struct InspectorHeading: View {
    let index: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(index)
                .font(.system(size: 24, weight: .light, design: .monospaced))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(Theme.engravedLabel)
                    .kerning(Theme.engravedTracking)
                Text(detail)
                    .font(Theme.readableFont)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
