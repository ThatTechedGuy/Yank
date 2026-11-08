// The row under the search box: a tab for History, one per pinboard, a "+" to make a new
// pinboard, and the filter button at the right. Clicking a tab switches the cards to that
// list; right-clicking a pinboard's tab offers Rename and Delete. ≈ a tab bar component with
// its own small dialogs.
//
// The name prompts and the delete confirmation are popovers, not alert sheets: the panel is a
// non-activating window (see PanelWindow), and a popover is the one kind of dialog proven to
// take typing on it without making Yank the active app (the large preview is one too).
import ClipCore
import SwiftUI

struct PanelTabs: View {
    let model: PanelModel

    /// The name typed so far in the Rename popover, and in the New Pinboard one. Which
    /// popover is open lives in the model, so the panel's key handling can tell a prompt is
    /// up (see `isPrompting`).
    @State private var renameText = ""
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 4) {
            // The tabs scroll sideways when there are more than fit, instead of pushing the
            // filter button off the panel.
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    tab("History", list: .history)
                        .accessibilityIdentifier("tab-history")
                    ForEach(model.pinboards) { pinboard in
                        tab(pinboard.name, list: .pinboard(id: pinboard.id))
                            .contextMenu {
                                Button("Rename…") {
                                    renameText = pinboard.name
                                    model.renamingPinboard = pinboard
                                }
                                Button("Delete…") { model.deletingPinboard = pinboard }
                            }
                            .popover(
                                isPresented: isPresenting($model.renamingPinboard, pinboard),
                                arrowEdge: .bottom
                            ) {
                                namePrompt("Rename Pinboard", button: "Rename", text: $renameText) {
                                    model.renamePinboard(pinboard, to: renameText)
                                    model.renamingPinboard = nil
                                }
                            }
                            .popover(
                                isPresented: isPresenting($model.deletingPinboard, pinboard),
                                arrowEdge: .bottom
                            ) {
                                deletePrompt(pinboard)
                            }
                            .accessibilityIdentifier("tab-\(pinboard.id)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button {
                model.newPinboardPrompt = NewPinboardPrompt()
            } label: {
                // An icon-only button still needs words for VoiceOver: a `Label` with the
                // `.iconOnly` style shows just the "+" and gives VoiceOver the title.
                Label("New Pinboard", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("New Pinboard")
            .accessibilityIdentifier("new-pinboard")
            // The New Pinboard prompt opens on the "+" whether the "+" or ⌘P asked for it.
            .popover(
                isPresented: Binding(
                    get: { model.newPinboardPrompt != nil },
                    set: { if !$0 { model.newPinboardPrompt = nil } }
                ), arrowEdge: .bottom
            ) {
                namePrompt("New Pinboard", button: "Create", text: $newName) {
                    if let prompt = model.newPinboardPrompt {
                        model.createPinboard(named: newName, for: prompt)
                    }
                }
                .onAppear { newName = "" }
            }
            Spacer()
            FilterMenu(model: model)
        }
        .padding(.horizontal, 12)
    }

    /// One tab: bold with a tinted capsule behind it when it is the current list.
    private func tab(_ title: String, list: ItemList) -> some View {
        let isCurrent = model.filter.list == list
        return Button(title) { model.filter.list = list }
            .buttonStyle(.borderless)
            .font(.callout.weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isCurrent ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// A binding that is true while `state` holds this pinboard; setting it false (the popover
    /// closing) clears the state. One popover per tab, so each needs its own yes/no.
    private func isPresenting(_ state: Binding<Pinboard?>, _ pinboard: Pinboard) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue == pinboard },
            set: { if !$0 { state.wrappedValue = nil } }
        )
    }

    /// A one-line name box with a button; Return does the same as the button.
    private func namePrompt(
        _ title: String, button: String, text: Binding<String>, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack {
                TextField("Name", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(action)
                    .accessibilityIdentifier("pinboard-name")
                Button(button, action: action)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    /// Asks before a pinboard goes, and says what happens to its items.
    private func deletePrompt(_ pinboard: Pinboard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete “\(pinboard.name)”?").font(.headline)
            Text("Its items go back to History.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.deletingPinboard = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    model.deletePinboard(pinboard)
                    model.deletingPinboard = nil
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("delete-pinboard")
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
