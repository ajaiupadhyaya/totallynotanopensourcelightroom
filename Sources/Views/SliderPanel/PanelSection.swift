import SwiftUI

/// A collapsible develop-panel section with an engraved label.
///
/// The header reads like a label plate on darkroom equipment — small caps,
/// tracked wide, over a hairline rule. Sections remember whether they were
/// collapsed across launches (keyed by title), because a photographer who
/// never touches Effects shouldn't have to fold it away every session.
///
/// A section can also surface a `reset` action, shown only while the section
/// contains non-neutral edits — the affordance appears exactly when it means
/// something.
struct PanelSection<Content: View>: View {
    let title: String
    var isModified: Bool = false
    var onReset: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @AppStorage private var isExpanded: Bool
    @State private var isHovering = false

    init(
        _ title: String,
        isModified: Bool = false,
        onReset: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
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
                .padding(.bottom, 14)
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
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
                    Button("Reset") { onReset() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.horizontal, Theme.panelInset)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title) section")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}
