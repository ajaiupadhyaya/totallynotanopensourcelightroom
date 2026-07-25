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
                .padding(.bottom, Theme.space3)

            Rule()

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
        .overlay(alignment: .bottom) { Rule() }
    }

    private var maskWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.space4) {
                InspectorHeading(
                    title: "Masks",
                    detail: model.editStack.localAdjustments.isEmpty
                        ? "Take the Brush or Gradient from the rail to correct part of the frame."
                        : "Corrections that apply to part of the frame only."
                )

                LocalAdjustmentPanel(model: model)

                Rule()

                InspectorHeading(
                    title: "Repair",
                    detail: model.editStack.retouch.isEmpty
                        ? "Take Heal or Clone from the rail to remove a mark."
                        : "Heal, clone, and content-aware removals on this frame."
                )
                RetouchPanel(model: model)
            }
            .padding(Theme.panelInset)
        }
    }

    private var historyWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeading(
                    title: "History",
                    detail: "Every committed state is still here. Select one to return to it."
                )
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
                                    .font(Theme.body)
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
                    Text("NAMED STATES").sectionLabel()
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
        HStack(spacing: Theme.space2) {
            diagnosticToggle(
                "Shadows",
                fraction: model.histogram.shadowClippedFraction,
                isClipping: model.histogram.isClippingShadows,
                isOn: $model.showsShadowClipping
            )
            diagnosticToggle(
                "Highlights",
                fraction: model.histogram.highlightClippedFraction,
                isClipping: model.histogram.isClippingHighlights,
                isOn: $model.showsHighlightClipping
            )
        }
    }

    /// One clipping readout, which is also the switch for its overlay.
    ///
    /// The number is always shown; the warning colour appears only when the
    /// reading actually matters. Combining the readout and the control is
    /// deliberate — noticing a clipped highlight and wanting to see *where* is
    /// one thought, and it should be one click.
    private func diagnosticToggle(
        _ label: String, fraction: Double, isClipping: Bool, isOn: Binding<Bool>
    ) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                if isClipping {
                    Icon.Filled(kind: .warningTriangle, size: 8)
                        .foregroundStyle(Theme.warning)
                }

                Text(label.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .kerning(0.7)
                    .foregroundStyle(isOn.wrappedValue ? Theme.text : Theme.tertiaryText)

                Spacer(minLength: 2)

                Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                    .font(Theme.valueFont)
                    .monospacedDigit()
                    .foregroundStyle(isClipping ? Theme.warning : Theme.secondaryText)
            }
            .padding(.horizontal, Theme.space2)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(
                isOn.wrappedValue ? Theme.controlActive : Theme.control.opacity(0.5),
                in: RoundedRectangle(cornerRadius: Theme.radius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(isOn.wrappedValue ? Theme.accent.opacity(0.6) : Theme.separator,
                                  lineWidth: Theme.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: isOn.wrappedValue)
        .help(isOn.wrappedValue
              ? "Hide the \(label.lowercased()) clipping overlay"
              : "Show where \(label.lowercased()) are clipping")
        .accessibilityLabel("\(label) clipping")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(1))))
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }
}

/// A workspace heading: what this pane is, then what to do with it.
///
/// The previous version put a large accent letter beside each title — "M" for
/// masks, "H" for history. It looked like structure but encoded nothing: the
/// letters were the first letter of the word already printed next to them. The
/// space goes to the sentence instead, which in an empty pane is the only
/// instruction on screen.
private struct InspectorHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.heading)
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
