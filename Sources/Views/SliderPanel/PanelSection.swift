import AppKit
import SwiftUI

/// Solo over the sections' own persistence: writes the same
/// `panel.v3.expanded.<title>` keys every `PanelSection.@AppStorage` reads,
/// so soloing IS expansion state and survives relaunch like any fold.
enum PanelExpansion {
    static func key(_ title: String) -> String { "panel.v3.expanded.\(title)" }

    /// Opens `title`, folds every other listed section. Writes every key, so
    /// the state is fully materialised afterwards.
    static func solo(_ title: String, among titles: [String],
                     defaults: UserDefaults = .standard) {
        for t in titles { defaults.set(t == title, forKey: key(t)) }
    }

    /// True only for a materialised solo: this section open, all others shut.
    static func isSolo(_ title: String, among titles: [String],
                       defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(title))
            && titles.allSatisfy { $0 == title || !defaults.bool(forKey: key($0)) }
    }
}

/// A collapsible develop-panel section, numbered by its position in the render
/// pipeline and threaded onto the signal chain's spine.
///
/// ## The spine
///
/// Every section's stage index sits in a fixed gutter down the left of the
/// develop column, and a hairline runs through that gutter connecting them. It
/// is not a rule for decoration: the numbers really are the order the renderer
/// runs in, film conversion first and effects last, and the spine lights up
/// beside any stage carrying edits.
///
/// That turns the column into a single readable answer to the question a
/// photographer asks constantly — *what have I actually done to this frame?* —
/// which is otherwise buried inside thirteen collapsed sections. A folded
/// section keeps its state visible instead of hiding it.
///
/// Sections remember whether they were collapsed across launches (keyed by
/// title), because someone who never touches Effects shouldn't have to fold it
/// away every session.
struct PanelSection<Content: View>: View {
    let title: String
    var index: String?
    var isModified: Bool = false
    var onReset: (() -> Void)?

    /// The sections a ⌥-click solos among. Nil means this section has no solo
    /// group and ⌥-click just folds, like an ordinary click.
    var soloTitles: [String]?
    @ViewBuilder let content: () -> Content

    @AppStorage private var isExpanded: Bool
    @State private var isHovering = false

    init(
        _ title: String,
        index: String? = nil,
        isModified: Bool = false,
        onReset: (() -> Void)? = nil,
        soloTitles: [String]? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.index = index
        self.isModified = isModified
        self.onReset = onReset
        self.soloTitles = soloTitles
        self.content = content
        // A fresh inspector opens on Light, the most common operation, while
        // the rest of the chain stays legible as a compact index. Process
        // opens too — it's an action waiting on the user, not a pipeline
        // stage to browse, so it must not hide behind a disclosure triangle.
        _isExpanded = AppStorage(wrappedValue: title == "Light" || title == "Process",
                                 "panel.v3.expanded.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.controlSpacing) {
                    content()
                }
                .padding(.leading, Theme.stageGutter)
                .padding(.trailing, Theme.panelInset)
                .padding(.top, 4)
                .padding(.bottom, Theme.space4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isExpanded ? Theme.surface : Theme.surface.opacity(0.6))
        .overlay(alignment: .topLeading) { Rule() }
        .overlay(alignment: .leading) { spine }
        .clipped()
    }

    /// The chain running through the index gutter. It brightens to the accent
    /// beside a stage that is carrying edits, so the column reads at a glance.
    private var spine: some View {
        Rectangle()
            .fill(isModified ? Theme.accent.opacity(0.65) : Theme.separator)
            .frame(width: isModified ? 2 : Theme.hairline)
            .padding(.leading, Theme.panelInset - 3)
            .animation(Theme.standard, value: isModified)
    }

    /// True while this section is the only open one in its solo group — the
    /// state ⌥-click produces, read back so the chevron can say so.
    private var isSoloed: Bool {
        guard let soloTitles else { return false }
        return PanelExpansion.isSolo(title, among: soloTitles)
    }

    private var header: some View {
        Button {
            // ⌥-click solos: this section open, the rest of the column folded.
            if let soloTitles, NSEvent.modifierFlags.contains(.option) {
                withAnimation(Theme.expand) {
                    PanelExpansion.solo(title, among: soloTitles)
                }
            } else {
                withAnimation(Theme.expand) { isExpanded.toggle() }
            }
        } label: {
            HStack(spacing: 0) {
                // The gutter: stage index, on the spine. An unnumbered
                // section renders an invisible placeholder rather than an
                // empty Group — modifiers on a view that renders nothing
                // collapse, which left "Process"'s title 0.5pt from the
                // panel edge while every numbered section sat on the gutter
                // (the design audit measured 1px vs 81px).
                Text(index ?? "00")
                    .font(Theme.indexFont)
                    .foregroundStyle(isModified ? Theme.accent : Theme.tertiaryText)
                    .opacity(index == nil ? 0 : 1)
                    .frame(width: Theme.stageGutter, alignment: .leading)
                    .padding(.leading, Theme.panelInset)

                Text(title.uppercased())
                    .sectionLabel(isExpanded || isModified ? Theme.text : Theme.secondaryText)

                Spacer(minLength: Theme.space2)

                if let onReset, isModified, isHovering {
                    Button(action: onReset) {
                        Text("RESET")
                            .plateLabel()
                            .foregroundStyle(Theme.tertiaryText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reset \(title)")
                    .transition(.opacity)
                }

                Icon(kind: isExpanded ? .chevronDown : .chevronRight, size: 10, weight: 1.3)
                    .foregroundStyle(isSoloed ? Theme.accent
                                              : (isHovering ? Theme.secondaryText
                                                            : Theme.tertiaryText))
                    .padding(.trailing, Theme.panelInset)
                    .padding(.leading, Theme.space2)
            }
            .frame(height: 38)
            .background(isHovering ? Theme.raisedSurface : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(soloTitles == nil ? "Click to fold" : "Click to fold · ⌥-click to solo")
        .onHover { isHovering = $0 }
        .animation(Theme.quick, value: isHovering)
        .accessibilityLabel("\(title) section")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint(isModified ? "Contains edits" : "")
    }
}

/// A quiet divider naming a run of pipeline stages.
///
/// Thirteen numbered sections in a row is a list, not a structure. Grouping
/// them by what the stages *do* — repair the frame, place the tones, grade the
/// colour — gives the column a rhythm to scan by without renumbering anything
/// or pretending the pipeline is shorter than it is.
struct PanelGroupHeading: View {
    let title: String

    var body: some View {
        HStack(spacing: Theme.space2) {
            Text(title.uppercased())
                .font(Theme.plateFont)
                .kerning(1.4)
                .foregroundStyle(Theme.tertiaryText.opacity(0.85))
            Rule(color: Theme.separator.opacity(0.7))
        }
        .padding(.leading, Theme.panelInset)
        .padding(.trailing, Theme.panelInset)
        .padding(.top, Theme.space5)
        .padding(.bottom, Theme.space2)
        .background(Theme.background.opacity(0.5))
    }
}
