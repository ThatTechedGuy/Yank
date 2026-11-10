// The pin rows for one card. The same rows serve the card's right-click menu and the chooser ⌘P
// opens when there is more than one pinboard: SwiftUI draws the buttons as menu rows in a menu
// and as a column of buttons in a popover.
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
