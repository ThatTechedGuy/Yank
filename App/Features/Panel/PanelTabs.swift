// The tabs next to the search box, centred in the panel's top bar: History, one per pinboard, and a "+".
// Its prompts are popovers, not alert sheets: on the non-activating panel (see PanelWindow) a
// popover is the one kind of dialog proven to take typing without making Yank the active app.
import ClipCore
import SwiftUI

struct PanelTabs: View {
    let model: PanelModel

    /// The names typed so far in the Rename and New Pinboard popovers. Which popover is open
    /// lives in the model, so the panel's key handling can tell a prompt is up.
    @State private var renameText = ""
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 4) {
            // The tabs sit at their own width so the bar can centre them, and scroll sideways
            // only when there are more than fit.
            ViewThatFits(in: .horizontal) {
                tabs
                ScrollView(.horizontal) { tabs }
                    .scrollIndicators(.never)
            }
            Button {
                model.newPinboardPrompt = NewPinboardPrompt()
            } label: {
                // A `Label`, not an `Image`, so VoiceOver still gets the title.
                Label("New Pinboard", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15))
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
        }
    }

    /// History, then one tab per pinboard.
    private var tabs: some View {
        @Bindable var model = model
        return HStack(spacing: 4) {
            tab("History", systemImage: "clock.arrow.circlepath", list: .history)
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

    /// One tab, as in Paste: a grey capsule behind the current one, medium weight, in the
    /// label colour either way.
    private func tab(_ title: String, systemImage: String? = nil, list: ItemList) -> some View {
        let isCurrent = model.filter.list == list
        return Button {
            model.filter.list = list
        } label: {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isCurrent ? Color.primary.opacity(0.1) : .clear, in: Capsule())
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
