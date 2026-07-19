import SwiftUI

/// A collapsible develop-panel section with an engraved, stage-numbered label.
///
/// The header reads like the title block of a drawing: a dim stage index, then
/// the section name in tracked caps over a hairline rule. The indices aren't
/// decoration — they are the order of the render pipeline itself, so the panel
/// column doubles as a legend of the signal chain.
///
/// Sections remember whether they were collapsed across launches (keyed by
/// title), because a photographer who never touches Effects shouldn't have to
/// fold it away every session. A section can also surface a `reset` action,
/// shown only while the section contains non-neutral edits — the affordance
/// appears exactly when it means something.
struct PanelSection<Content: View>: View {
    let title: String
    var index: String?
    var isModified: Bool = false
    var onReset: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @AppStorage private var isExpanded: Bool
    @State private var isHovering = false

    init(
        _ title: String,
        index: String? = nil,
        isModified: Bool = false,
        onReset: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.index = index
        self.isModified = isModified
        self.onReset = onReset
        self.content = content
        _isExpanded = AppStorage(wrappedValue: true, "panel.expanded.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.controlSpacing) {
                    content()
                }
                .padding(.horizontal, Theme.panelInset)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                if let index {
                    Text(index)
                        .font(Theme.indexFont)
                        .foregroundStyle(Theme.tertiaryText.opacity(0.8))
                }

                Text(title.uppercased())
                    .engraved()

                // A quiet dot marks a section carrying edits even when folded,
                // so state is never hidden by the fold.
                if isModified {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 4, height: 4)
                }

                Spacer()

                if let onReset, isModified, isHovering {
                    Button {
                        onReset()
                    } label: {
                        Text("RESET")
                            .font(Theme.plateFont)
                            .kerning(Theme.plateTracking)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }

                Glyph(kind: isExpanded ? .chevronDown : .chevronRight, size: 6, weight: 1.1)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, Theme.panelInset)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title) section")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}
