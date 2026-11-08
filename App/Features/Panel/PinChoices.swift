// The pin rows for one card: "Unpin" when it is on a pinboard, otherwise one "Pin to …" row per
// pinboard and "Pin to New Pinboard…". The same rows serve as the card's right-click menu and
// as the small chooser ⌘P opens on the card when there is more than one pinboard: in a menu,
// SwiftUI draws the buttons as menu rows; in a popover, as a column of buttons.
import ClipCore
import SwiftUI

struct PinChoices: View {
    let item: ClipboardItem
    let model: PanelModel

    var body: some View {
        if item.pinboardId != nil {
            Button("Unpin") { model.unpin(item.id) }
        } else {
            ForEach(model.pinboards) { pinboard in
                Button("Pin to “\(pinboard.name)”") { model.pin(item.id, to: pinboard.id) }
            }
            Button("Pin to New Pinboard…") {
                model.pinChooserItemId = nil
                model.newPinboardPrompt = NewPinboardPrompt(itemIdToPin: item.id)
            }
        }
    }
}
