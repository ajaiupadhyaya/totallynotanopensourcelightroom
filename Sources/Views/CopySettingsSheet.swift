import SwiftUI

/// The scoped-copy dialog: one lamp per numbered pipeline section, with the
/// modified ones flagged the same way the panel spine flags them.
struct CopySettingsSheet: View {
    let app: AppModel

    @State private var sections = TransferScope.default.sections

    private var stack: EditStack? { app.editor?.editStack }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            Text("COPY SETTINGS").sectionLabel(Theme.text)

            HStack(spacing: Theme.space2) {
                PlateButton(title: "All") { sections = TransferScope.all.sections }
                PlateButton(title: "None") { sections = TransferScope.none.sections }
                PlateButton(title: "Modified") {
                    if let stack { sections = TransferScope.modified(in: stack).sections }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(PipelineSection.allCases, id: \.self) { section in
                    HStack(spacing: Theme.space2) {
                        Text(section.index)
                            .font(Theme.indexFont)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 20, alignment: .trailing)
                        LampToggle(label: section.title, isOn: Binding(
                            get: { sections.contains(section) },
                            set: { if $0 { sections.insert(section) } else { sections.remove(section) } }
                        ))
                        Spacer()
                        if let stack, section.isModified(in: stack) {
                            Circle().fill(Theme.accent).frame(width: 4, height: 4)
                        }
                    }
                }
            }

            Text("Film carries the stock's character and the print look — "
                 + "never the sampled base or the scan's own solve. Frame and "
                 + "Retouch belong to the individual photograph.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                PlateButton(title: "Cancel") { app.isShowingCopySettingsSheet = false }
                PlateButton(title: "Copy", emphasis: .prominent) {
                    if let entry = app.editor?.entry {
                        app.copySettings(from: entry, scope: TransferScope(sections: sections))
                    }
                    app.isShowingCopySettingsSheet = false
                }
            }
        }
        .padding(Theme.space5)
        .frame(width: 300)
        .background(Theme.surface)
        .onAppear { sections = app.copiedScope.sections }
    }
}
