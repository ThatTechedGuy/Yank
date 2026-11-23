// The filter button at the right of the tab row and its menu. The icon fills in while anything
// is narrowed, so a short list is never a mystery. The user-facing names of the kinds and ranges
// live here too, where the menu and the cards both read them.
import ClipCore
import SwiftUI

struct FilterMenu: View {
    let model: PanelModel

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Type", selection: $model.filter.kind) {
                Text("Any Type").tag(ItemKind?.none)
                ForEach(ItemKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
            }
            .pickerStyle(.inline)
            Picker("Date", selection: $model.filter.dateRange) {
                ForEach(DateRange.allCases, id: \.self) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.inline)
            // Submenus: inline, twenty languages would make the menu taller than the screen.
            Picker("Category", selection: $model.filter.categoryId) {
                Text("Any Category").tag(Int64?.none)
                ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            Picker("Language", selection: $model.filter.language) {
                Text("Any Language").tag(String?.none)
                ForEach(Language.all.filter { $0 != Language.none }, id: \.self) {
                    Text($0).tag(Optional($0))
                }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Clear Filters") {
                model.filter.kind = nil
                model.filter.dateRange = .anyTime
                model.filter.categoryId = nil
                model.filter.language = nil
            }
            .disabled(!model.filter.isNarrowed)
        } label: {
            Label(
                "Filter",
                systemImage: model.filter.isNarrowed
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
            .foregroundStyle(model.filter.isNarrowed ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by type, date, category and language")
        .accessibilityIdentifier("filter")
    }
}

extension ItemKind {
    /// The kind as the user reads it, on the card's header and in the filter menu.
    var displayName: String {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .link: "Link"
        case .file: "File"
        case .color: "Color"
        }
    }
}

extension DateRange {
    /// The range as the filter menu shows it.
    var displayName: String {
        switch self {
        case .today: "Today"
        case .lastSevenDays: "Last 7 Days"
        case .lastThirtyDays: "Last 30 Days"
        case .anyTime: "Any Time"
        }
    }
}
