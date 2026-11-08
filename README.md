# Yank

A Paste-style clipboard manager for macOS 26 and later. Menu bar only, sandboxed, no sync. The full
spec is the plan at `~/Documents/clipboard-manager-plan.html` on thattechedguy's Mac: the single source of
truth, kept outside the repo on purpose. Finished work is struck through there and every decision made
while building is in its change log; every build thread reads it first. This README covers building,
testing and what we learned.

## Build and run

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen                     # creates Yank.xcodeproj from project.yml (it is not committed)
open Yank.xcodeproj          # then press ⌘R in Xcode, or:
xcodebuild -scheme Yank -derivedDataPath build -destination 'platform=macOS,arch=arm64' build
open build/Build/Products/Debug/Yank.app
```

`project.yml` is the source of truth for targets, build settings, signing and dependencies. Change it,
not the Xcode project, then run `xcodegen` again. Adding or removing a Swift file also needs a rerun.

Signing uses the "Apple Development" certificate of team `ZT5VFPR74U`. A stable signature matters: macOS
ties permissions such as Accessibility to it, so an unsigned or ad hoc build loses them on every rebuild.

## Layout

| Path | What lives there |
| --- | --- |
| `App/` | The app target: windows, menu bar, panel. May import ClipCore, ClipSystem, SwiftUI, AppKit, KeyboardShortcuts. `Features/Developer/` is the debug-only Developer window. |
| `App/Resources/Assets.xcassets` | The app icon, `AppIcon` (10 PNG slots, 16 to 1024 px). The menu bar uses the SF Symbol `list.clipboard` instead. Masters and a `build.py` that regenerates the PNGs are in `~/Downloads/Yank-icons/source`, not in the repo. |
| `Packages/ClipCore/Sources/ClipCore` | Model, rules, storage, services, ports. Foundation, CryptoKit, os only; GRDB only in `Storage/`. `Developer/` and `Storage/StoreInspector.swift` exist in debug builds only. |
| `Packages/ClipCore/Sources/ClipSystem` | Adapters that talk to macOS, implementing ClipCore's ports. |
| `AppUITests/` | XCTest UI tests that drive the real app. |
| `scripts/` | `test.sh`, `check-imports.sh`. |

## Code style

- **Comments teach.** The code is commented heavily on purpose. Every comment says what the code does,
  why it is needed and how it works, in simple plain English with no jargon, and relates Swift and macOS
  ideas to TypeScript, React/React Native and Android where that helps. A note about Swift syntax is
  allowed only as a short tail after that, never on its own. This replaces the plan's house rule 2
  ("comments only explain why") at the requester's request. New code follows the same style. Comments
  describe the code only: they never mention the plan, its stages or acceptance-criteria IDs.
- **Formatting:** `swift format` (bundled with Xcode). `.swift-format` sets 4-space indents and 110-column
  lines; JSON allows no comments, so it is explained here. Format with
  `swift format --in-place --recursive App AppUITests Packages/ClipCore`, check with `swift format lint`.
- **Database access goes through GRDB's record API** (`FetchableRecord`, `PersistableRecord`, `filter`,
  `order`, `insert`, `update`, `deleteAll`), never hand-written SQL. The only exceptions are things the
  query builder cannot say, such as a full-text `MATCH` (done through `FTS5Pattern`), and each one has
  a comment saying why. See `Storage/Records.swift`.

Logs: open Console.app and filter on subsystem `com.thattechedguy.Yank`, or run
`log stream --predicate 'subsystem == "com.thattechedguy.Yank"' --info`.

## Tests

```sh
scripts/test.sh --fast   # import check + package tests (minus the slow ones), a few seconds, no app launch
scripts/test.sh          # everything: slow package tests too, then the UI tests (quits a running Yank first)
```

Package tests tagged `.slow` (the tag is in `Tests/ClipCoreTests/Fakes/Fakes.swift`) seed 100,000 items
and take a few seconds each; `--fast` skips them by name (`swift test --skip /slow`), so give a slow
test a name that starts with `slow`.

UI tests drive the real app and may write to your clipboard. They use XCTest, not Swift Testing, because
`XCUIApplication` (launch an app, click its menus) exists only in XCTest; checked against the Xcode 27.2
SDK, where `Testing.framework` has no UI-driving API. Package tests use Swift Testing.

To test the privacy rules by hand without a password manager, put a marked copy on the clipboard and
check that the count in the menu doesn't move:

```sh
osascript <<'EOS'
use framework "AppKit"
set pb to current application's NSPasteboard's generalPasteboard()
pb's clearContents()
pb's setString:"secret" forType:"public.utf8-plain-text"
pb's setString:"" forType:"org.nspasteboard.ConcealedType"
EOS
```

## How a copy is saved (stage 1)

`AppModel` polls `NSPasteboard.general.changeCount` four times a second. When it changes,
`CaptureService` records the frontmost app, waits 0.3 s for the source app to finish writing, then runs
`PrivacyRules` on the type names only: a marker type (`org.nspasteboard.ConcealedType` and friends) or an
app on the user's ignored list (empty until Settings exist) means the data is never read. There is no
built-in list of password managers: 1Password, the Bitwarden desktop app and KeePassXC set the marker
themselves; Apple Passwords is reported to; Enpass is unverified, and the Bitwarden browser extension
cannot set it (the copy comes from the browser, so an ignored-apps entry would not catch it either).
The rules and the read happen in one `SystemClipboard.read` call: the rules see the type names first and
only if they allow it is the data of those same items read, so a copy that lands in between cannot slip
past the check. `Store.save` then hashes the defining content (`DuplicateKey`), works out the kind
(`ItemKind.detect`), builds the card text and writes one `clipboardItem` row plus one `clipboardItemData`
row per type, in a single transaction. Data over 1 MB goes to a file `LargeData/<random UUID>.bin` next to
the database; the row stores the file name. Files are written before the transaction and deleted after it
commits, so a crash can only leave an unused file, never a row pointing at a missing one; `Store.init`
sweeps unused files. A repeat copy moves the existing item to the top instead of adding a row, and the menu
re-reads the count from the database so it stays right. Whatever is on the clipboard when the app launches
is not saved.

Data lives in the sandbox container: `~/Library/Containers/com.thattechedguy.Yank/Data/Library/Application
Support/Yank/` (`yank.sqlite` plus `LargeData/`). Delete that folder to start fresh.

**Clipboard permission.** On macOS 15.4 and later the first read shows "Yank would like to paste from
<app>". Choose **Allow**; then open System Settings › Privacy & Security › Paste from Other Apps and set
Yank to **Allow** once, so it never asks again. While it is set to Ask or Deny, the menu says so and offers
a button to that page. (The button's `x-apple.systempreferences:` URL is a community-documented scheme,
not an Apple API, so re-check it after macOS updates.)

**Big or lazy copies on the main thread:** not measured yet. Two cases matter: a 200 MB image, and a
"lazy" copy, where the source app (Numbers, Excel, a browser) promises types and only renders the data when
asked, which can stall the read. The read logs its duration; hand check by copying a large range in Numbers
and a big image, then `log show --last 5m --predicate 'subsystem == "com.thattechedguy.Yank"' --info`. The
decision goes here.

## The panel and the card row (stage 2)

Press ⇧⌘V in any app and a strip of cards appears along the bottom of the screen the mouse is on; press it
again, press Esc, or click anywhere else to hide it. The window is `PanelWindow` in `App/Features/Panel/`,
an `NSPanel` (AppKit's class for floating helper windows) with the `nonactivatingPanel` style: it can take
key presses without making Yank the active app, so the app you were in stays in front and its menu bar
stays put. That is the one thing SwiftUI's own `Window` cannot do, so the window is AppKit and only its
content is SwiftUI (`PanelView`, hosted with `NSHostingView`). It floats above everything (`level =
.mainMenu`), appears on every Space and over full-screen apps, and hides itself when it stops being the key
window (`resignKey`), which is what "click outside" means to AppKit. A mouse's vertical wheel is turned
into sideways scrolling in `sendEvent` by swapping the axes of the underlying `CGEvent`; trackpad events
report "precise" deltas and are left alone, because a two-finger swipe already goes sideways.

The content is a search field (see the search section), a horizontal `LazyHStack`
of `ItemCard`s inside a `ScrollView`, and `PanelModel`, an `@Observable` class (≈ a store in Zustand or a
ViewModel) that owns the list and the selected item. The list is one live GRDB query,
`Store.observeItems(limit:)` (a `ValueObservation`): the database tells the model when rows change, so a
new copy appears on the strip while it is open. Paging is "one growing query": the model starts with 200
items and, when a card near the end appears on screen (`cardDidAppear`), raises the limit by 200 and
restarts the query. Hiding the panel resets the limit and the selection. ←/→ move the selection, Tab
toggles between the search field and the row, ⌘1–⌘9 are shown in the footers. Cards show the kind (SF Symbol + label), the text or a description, a relative time
("2 minutes ago", refreshed every minute by `TimelineView`) and the source app.

The ⇧⌘V shortcut is `KeyboardShortcuts.Name.togglePanel` in `App/ShortcutNames.swift`; `AppModel` loops
over `KeyboardShortcuts.events(.keyDown, for:)` and toggles the panel. The shortcut is recorded in
UserDefaults by the package, so a Settings recorder later changes it without code. Paste.app uses the same
keys: quit Paste before trying Yank.

**Debug launch flags** (`App/LaunchOptions.swift`, compiled out of release builds): `--seed N` wipes a
separate fake-history database (`Application Support/Yank-seed/`, never the real one) and fills it with N
items of every kind; `--show-panel` opens the panel as soon as the app is ready. `AppUITests/PanelTests`
uses both. Try 100,000 items with
`build/Build/Products/Debug/Yank.app/Contents/MacOS/Yank --seed 100000 --show-panel`.

**Measurements (M-series Mac, debug build).** Opening is timed in `AppModel.togglePanel` from the key
event to just after `makeKeyAndOrderFront`, and logged as "panel opened in X ms" (also an `OSSignposter`
interval "Open panel" for Instruments). 10,000 items: 32.5 ms for the first open, then under 1 ms. 100,000
items: 19.5 ms, then under 1 ms. Memory (`footprint Yank`) with 100,000 items and the panel open: 72 MB,
peak 82 MB. Limits are 50 ms, 100 MB at 10k and 200 MB at 100k. Caveat: the timer stops when the window
is ordered front, not when its first frame is drawn, so it understates what the eye sees by a few ms.

**Decision: keep the SwiftUI card row.** `LazyHStack` with a 200-item growing query is well inside the
limits at 100,000 items, so there is no reason to build an AppKit `NSCollectionView` row. Revisit only if
cards gain thumbnails that make scrolling stutter.

**Maintaining it.** To show a new field on a card, add it to `ItemCard` (the data is the whole
`ClipboardItem`, so nothing else changes). To change the page size, edit `PanelModel.pageSize`. To change
the height, edit `PanelWindow.height`. New Swift files need `xcodegen` again. `scrollIndicators(.hidden)`
is set on the row, but macOS still draws a scroll bar when System Settings › Appearance › Show scroll bars
is "Always"; that is the system's choice, not a bug.

**Hand checks still open** (needs someone at the Mac; quit Paste first):

- ⇧⌘V from Safari, Finder and a full-screen app: the panel appears along the bottom of the screen with the
  mouse, the other app stays active, Esc and a click outside hide it.
- A real mouse's wheel scrolls the row sideways; a trackpad swipe still works.
- Open the panel with 100,000 items (`--seed 100000 --show-panel`) and scroll to the far end: it keeps up.
- Copy something while the panel is open: the new card appears at the left.
- Stage 1 carry-overs: a 200 MB image copied from Preview (read time in the log), a large range copied in
  Numbers (does the read stall?), and a real Finder ⌘C of several files (are they saved as file items?).

## Pasting (stage 3)

Return pastes the selected card into the app you were using; ⇧Return pastes it as plain text. ⌘1–⌘9 paste
the card with that number on its badge, a double-click pastes the clicked card, and ⇧ works with both. The
work is split the same way as capture: `PasteService` in ClipCore decides *what* happens, two ports say
*which system calls* it needs, ClipSystem implements them, and the app wires them up.

**What a paste does** (`Packages/ClipCore/Sources/ClipCore/Services/PasteService.swift`). It reads the
item's stored types from the Store; for a plain-text paste it keeps only `public.utf8-plain-text` (and
keeps everything when the item has no text, so a plain-text paste of an image still pastes the image). It
adds Yank's own marker type (`com.thattechedguy.yank.own-paste`, an empty extra type on the first
pasteboard item) so the capture loop recognises the write and does not save it again, writes the lot to
the clipboard, moves the item to the top of the history (`Store.moveToTop`, which sets `copiedAt` to
now), hides the panel, and then, if the destination is the active app and macOS allows it, presses ⌘V.
Errors are logged under the `paste` category, never shown: by then the item is on the clipboard, so the
user can always press ⌘V themselves.

**Why hiding waits.** The panel is the key window while it is open, so a ⌘V pressed straight after
`orderOut` could still land in our own search box. `PanelWindow.hide()` is therefore `async`: it orders
the window out and suspends until AppKit calls `resignKey()`, which is the moment the keyboard has moved
on. (A `CheckedContinuation` is the Swift way to turn "AppKit will call me back" into something you can
`await`, like wrapping a callback in a Promise.) On macOS 26 the call arrives before `orderOut` returns,
so there is no delay to tune; the wait is there in case a later macOS does it a moment afterwards. A real
paste into TextEdit was checked on the runner with the posted ⌘V: both Return and ⇧Return landed.

**Pressing ⌘V** (`Packages/ClipCore/Sources/ClipSystem/KeyPresser.swift`). macOS key events carry a
*key code* (the physical key), not a letter, and the key that types "v" moves with the keyboard layout.
`KeyPresser` asks [Sauce](https://github.com/Clipy/Sauce) (the Clipy project's layout library, also used
by Maccy; MIT; pinned to 2.5.2 in `Packages/ClipCore/Package.swift`) for the key that types "v" with ⌘
held on the current layout, then posts a key down and key up with the ⌘ flag through `CGEvent`. Sauce
reads each enabled layout's key table once, caches the answer and follows layout switches. Asking with ⌘
held is what makes "Dvorak – QWERTY ⌘" work: that layout types Dvorak letters but keeps QWERTY positions
for ⌘ shortcuts. Posting events needs the Accessibility
permission; `SystemAccessibilityStatus` wraps `AXIsProcessTrusted` and the "ask the user" variant.

**The hint.** When the panel opens, `PanelModel.didShow()` checks whether Return could press ⌘V
(destination is the active app and Accessibility is granted). If not, a one-line hint and an "Allow…"
button appear next to the search field; the button shows macOS's own permission dialog. Nothing else ever
prompts. The check runs on every open, so granting the permission is noticed on the next ⇧⌘V.

**Settings** (`App/Features/Paste/PasteSettings.swift`). "Paste items: to active app / to clipboard
only" and "Always paste as plain text" live in `UserDefaults` under the keys `pasteDestination`
(`activeApp` / `clipboardOnly`) and `alwaysPlainText`. The Settings window (later) edits the same keys
with `@AppStorage`, which is SwiftUI's view wrapper over the same store. Until then, set them for one run
from the command line, because macOS lets any `-key value` launch argument override a default:
`build/Build/Products/Debug/Yank.app/Contents/MacOS/Yank --seed 20 --show-panel -pasteDestination clipboardOnly -alwaysPlainText YES`.

**Tests.** `PasteServiceTests` (fakes for the clipboard, key presser and permission): plain text keeps one
type and falls back to all; the marker is always written; ⌘V is pressed once when allowed, never in
clipboard-only mode or without the permission; the item moves to the top. `KeyPresserTests` find the V key
on the real US, Dvorak and Dvorak – QWERTY ⌘ layouts (key codes 9, 47 and 9); Sauce only knows enabled
layouts, so the test adds the missing ones to the input menu for its duration and removes them after. `SystemClipboardTests`
write items and read them back. `PanelTests` presses Return and ⌘2 in clipboard-only mode and checks the
clipboard's change count and types (not its contents: reading them from the test process would trigger
the "Paste from Other Apps" prompt).

**Measurements (M-series Mac, debug build, 10,000 items).** Panel open 21.6 ms the first time, 1.8 ms
after. Idle CPU with the panel closed: 0.0–0.1% over 60 s (`top -l 7 -s 10`). Memory: 29 MB resident at
rest, 59 MB (peak 66 MB, `footprint`) after opening the panel. A copy made with the panel closed was saved
0.7 s after it was written (0.3 s settle wait plus up to 0.25 s of polling). All within the limits.

**Maintaining it.** To add a way to paste (a menu item, a gesture), call `model.paste(_:plainText:)` or
`model.pasteSelected(plainText:)`; the model adds the settings and the service does the rest. To change
what "plain text" keeps, edit the filter in `PasteService.paste`. A new setting goes in `PasteSettings`
with its key, and the service gets it as a parameter, so ClipCore never reads `UserDefaults`. If a layout
ever has no key that types "v" with ⌘ held, `KeyPresser` throws `KeyPressError.noKeyTypesV` and the paste
is logged. Sauce is written in Swift 5 mode and compiles clean under our Swift 6 strict settings with a
plain `import`; if a Sauce update ever brings concurrency warnings, `@preconcurrency import Sauce` in
`KeyPresser.swift` is the narrow fix.

**Hand checks still open** (needs someone at the Mac; quit Paste first, because it uses ⇧⌘V too):

- Accessibility allowed: in Notes, ⇧⌘V, pick a card, Return. Pasted at the cursor. Same in Safari.
- Accessibility off: same steps; the item is on the clipboard, the panel closes, the hint is shown, ⌘V
  pastes it. Click "Allow…" and check macOS's dialog opens.
- Dvorak and Dvorak – QWERTY ⌘ layouts: still pastes, no stray character.
- `-pasteDestination clipboardOnly`: Return puts the item on the clipboard and presses nothing.
- ⇧Return and ⇧-double-click paste formatted text (copied from Safari) into TextEdit without formatting;
  with `-alwaysPlainText YES`, Return does too.
- ⌘3 pastes the third card. (After a search, ⌘1 pastes the first result: once search exists.)
- Stage 2 carry-overs: ⇧⌘V from Safari, Finder and a full-screen app; Esc and click-outside; a real
  mouse wheel; scrolling to the end of 100,000 items; copying while the panel is open.
- Stage 1 carry-overs: a 200 MB image from Preview, a large range in Numbers, a real Finder ⌘C of several
  files.
## Search (stage 4)

Typing in the panel's search field filters the cards as you type. Each keystroke sets
`PanelModel.searchText`, whose `didSet` cancels the search still running for the previous text and starts
a new `Task` (cancel-and-restart, no debounce: a search is a few ms, so waiting for the typing to pause
would only add delay). The task calls `Store.search(_:limit:)` and, if it was not cancelled meanwhile,
assigns `searchResults`; `items` (what the views read) is `searchResults ?? liveItems`, so clearing the
field shows the live list again, which kept running underneath. Results are a snapshot: a copy made while
they show does not appear until the next keystroke. They are capped at one page (`pageSize`, 200) with no
paging, and `cardDidAppear` does not page while results show.

The search is SQLite's full-text index FTS5, through GRDB. The `clipboardItemSearchIndex` virtual table
mirrors `clipboardItem` (GRDB's `synchronize(withTable:)` installs the triggers that keep it in step) and
indexes `cardText`, `title`, `imageText`, `linkPageTitle` and `sourceAppName`, so "safari" finds what was
copied from Safari. The tokenizer is `unicode61` (case- and accent-insensitive, splits on punctuation) with
prefix tables for 2- and 3-letter prefixes, which is why the two-letter minimum exists: below it the index
has no prefix table and one letter matches most of the history. `Store.search` turns the typed text into
an `FTS5Pattern(matchingAllPrefixesIn:)`, so every word is a prefix ("qua" finds "quarterly"), every word
must match, and quotes, `OR`, `NOT`, `*` and apostrophes are ordinary characters, never operators. It
returns `nil` when there is nothing searchable yet (under two characters after trimming, or only
punctuation), and the model shows the full list then. The query is GRDB's query builder:
`ClipboardItem.joining(required: ClipboardItem.searchIndex.aliased(index).matching(pattern))`, ordered by
the index's `rank` (FTS5's bm25 score, lowest first) through a `TableAlias`, then `copiedAt` descending.

**Decision: score only narrow matches.** SQLite scores each matching row one at a time, about 1 µs per
row on an M-series Mac, so ranking all 50,000 matches of a two-letter search over 100,000 items took
35–45 ms, past the 33 ms limit. `Store.search` counts the matches first (about 1 ms) and orders by score
only when there are at most `Store.rankedMatchLimit` (5,000); broader searches come newest first, which
is what a history should do for a prefix of a common word anyway. Measured in `StoreTests`
(`slowSearchOverAHundredThousandItemsStaysWithinItsLimit`, 100,000 items, debug build): p95 of 12–14 ms
for the broad newest-first searches ("sa", "me", "mee"), 7 ms for "saf" (ranked), 4 ms for "pages 1"
(ranked).

**Timing signposts.** The whole search, from keystroke to results assigned, is the `OSSignposter`
interval `"Search"` in `Log.timing` (`PanelModel.startSearch`), next to `"Open panel"`; the `ui` log also
prints "search found N items" (N is -1 when the text was not a search). List them with
`log show --last 5m --signpost --predicate 'subsystem == "com.thattechedguy.Yank"'`.

**Maintaining it.** The index's columns are fixed when the table is created, so to search a new field add
a migration in `Migrations.swift` that drops `clipboardItemSearchIndex`, drops its triggers
(`dropFTS5SynchronizationTriggers`) and recreates it with the new column, the way `v2` does; FTS5 rebuilds
from `clipboardItem` on creation. Never edit a migration that has shipped. To change the ranking
threshold, edit `Store.rankedMatchLimit`; to change what counts as "too little to search", edit the guard
at the top of `Store.search`. Searching for an exact phrase or by kind would be a new `FTS5Pattern`
initializer or a `filter` on the joined request; see GRDB's `FullTextSearch.md`.

**Hand checks still open** (quit Paste first):

- Type a partial word ("quar") and a two-word search ("meet thu"): only matching cards show, the first is
  selected, and ←/→ still move. Clear the field: the full list is back.
- Type "safari": cards copied from Safari show even when the word is not in their text.
- Type `"hello`, `don't`, `c++`, `OR`, `NOT`, `*`: no error in the log, sensible results or the full list.
- Open with `--seed 100000 --show-panel`, type "sa" letter by letter, then
  `log show --last 2m --signpost --predicate 'subsystem == "com.thattechedguy.Yank"'`: each "Search"
  interval is under 33 ms.

## Previews and card design (stage 5)

Cards look like Paste's: a band at the top in the source app's colour with the kind ("Text", "File"), the
age and the app's icon; the content in the middle; a footer with the ⌘N badge and a one-line detail
("46 characters", "1.4 MB", "example.com", "1280 × 800", "#2B59D6"). Image and file cards show a
thumbnail; colour cards fill with the colour. The card's width follows the panel's height (`CardRow`,
0.82 × the row height), and the panel's height follows the user: drag the handle at its top edge
(`PanelView`, the `resize-handle`), between `PanelHeight.minimum` and `.maximum` (252–412 points, Paste's
own limits); `PanelWindow` saves it in `UserDefaults` and uses it on the next open.

**How a card gets its preview.** `Store.save` computes the footer detail it can from the bytes it already
has (`CardDetail.make`: character count, file size, link host) into the new `cardDetail` column
(migration `v3`). What needs decoding happens after the save, off the main thread, in `Enricher`:
`AppModel` wires it after each capture (`enrichInBackground`, priority `.utility`) and the card asks for
it again on screen if it is still missing. The Enricher reads the item's bytes and calls one function,
ClipSystem's `Thumbnailer.preview`, which uses ImageIO for images (`CGImageSourceCreateThumbnailAtIndex`,
at most 512 pixels on the long side, never scaled up, plus the real pixel size), Quick Look for files
(`QLThumbnailGenerator`, the same previews Finder shows) with the Finder icon as fallback, and
`NSKeyedUnarchiver` + `NSColor` for a colour's hex value. The answer is saved in one transaction
(`Store.setPreview`): the PNG in the `cardThumbnail` table (one row per item, deleted with it) and the
detail on the item. Text and links never reach the Thumbnailer. ClipCore stays free of AppKit: the
Enricher takes the function as a closure, so its tests pass a fake.

**On screen.** `ThumbnailCache` (an `NSCache` of decoded `NSImage`s, keyed by item id) hands a card its
picture: a hit is synchronous, a miss starts one load (`Store.thumbnail`, decoded off the main thread)
and the card redraws when it lands. A thumbnail is at most 512 pixels, so a row of ten thousand cards
never decodes a 50 MB photo. The source app's icon and tint come from `SourceAppIcons`
(`NSWorkspace.shared.icon(forFile:)` of the app found by bundle id, and `dominantColor`: the most common
saturated colour among its opaque pixels; grey when the icon has none).

**Large preview.** Space on the selected card (`PanelModel.togglePreview`): an image or a file opens in
Quick Look (`PanelView`'s `.quickLookPreview` bound to `model.quickLookURL`; `Store.quickLookFile` hands
Quick Look the file itself, or the item's bytes written to a temporary file with the right extension);
anything else opens `LargePreview`, a popover above the card with the full text (read on demand from the
Store) and its counts (`TextCounts`), the link with its site, or the colour swatch. Space while typing
a search with words in it stays a space. Esc closes the preview first and the panel second; moving the
selection or hiding the panel closes it too. Quick Look's panel is the system's and takes the keyboard
from nobody when it opens, because Yank is never the active app; `PanelWindow.resignKey` notices, moves
the Quick Look panel into the space above the panel on the same screen and takes the keyboard back, so
Esc, Space and the arrows keep working. A click inside Quick Look hands it the keyboard; from then on
the panel listens for its close (`willCloseNotification`: take the keyboard back) and for a click
elsewhere (`didResignKeyNotification` with no key window left: hide).

**Maintaining it.** To change what a footer says, edit `CardDetail.make` (save time) or
`Thumbnailer.preview` (after decoding); to add a kind of preview, add a case to both and the card's
`content` in `ItemCard`. The thumbnail size is `Thumbnailer.maxPixelSize`; the panel's limits are in
`PanelHeight`; the card's proportions are `cardWidth` in `CardRow`. The tint rule is
`SourceAppIcons.dominantColor`: tune its saturation threshold (0.25) there. Adding a column to a card
means a migration in `Migrations.swift`, never an edit to `v3`. Previews for items saved before this
version are made the first time their card appears.

**Hand checks still open** (quit Paste first):

- Copy a photo from Photos or Preview, a PDF from Finder, a colour from the Digital Color Meter and a
  long text: each card shows the right picture or swatch and the right footer; the photo shows its
  pixel size, the PDF its first page and size.
- Press Space on each kind: Quick Look for the photo and the PDF, on the panel's screen with the panel
  still in front; the popover for the text and the colour. Esc closes the preview, Esc again the panel.
  Click inside Quick Look, then press Esc: Quick Look closes and the panel is still open and takes keys.
- Drag the panel's top edge up and down: it stops at the limits and the cards grow with it; quit and
  relaunch: the height is kept.
- Copy a 200 MB TIFF: the card appears at once and the thumbnail a moment later; memory stays flat.
- Open Paste.app next to Yank with the same copies and compare the two side by side: the tints, the
  footer details and the card proportions.

## The Developer window (stage 4b)

Debug builds only. The menu bar menu gains **Developer…**, a window with four tabs, and **Open Data
Folder**, which selects the database file in Finder. The whole of `App/Features/Developer/` and the three
ClipCore pieces it uses sit under `#if DEBUG` (≈ `__DEV__`, except the compiler drops the code), so a
release build contains none of it: `strings` on the Release binary finds no "Developer", "StoreInspector"
or "Open Data Folder". Every tab does its work from its `.task`, which SwiftUI cancels when the tab or
the window goes away, so with the window closed the app does nothing extra (`top` shows 0.0 %). All tabs
pause while the panel is open, so they never overlap a timing.

- **Overview**: item counts per kind, search-index rows, database and large-data sizes, memory footprint
  and CPU. Once a second. The footprint is `ri_phys_footprint` from `proc_pid_rusage`
  (`ClipCore/Developer/ProcessSample.swift`), the same number the `footprint` tool reports. The window's
  own drawing shows up in the CPU figure, so **Measure for 60 Seconds** hides the window, samples with
  nothing drawing, and shows it again with the result (0.2 % idle with 1,000 items). Instruments stays the
  final word.
- **Database**: a read-only browser of every table in the file, like DB Browser for SQLite: a picker of
  the tables with their row counts (the app's four, the FTS5 search index and the five shadow tables it
  keeps, `grdb_migrations`, `sqlite_sequence`; found by asking `sqlite_master`, so a table added by a
  later migration appears by itself; the app's own first, then the ones with an underscore), then every column of the chosen table, 200 rows per page, with ◀ ▶
  to page. Rows come in SQLite's scan order (rowid, oldest first). A blob cell shows its size plus the
  text or image inside when the bytes say so (PNG/JPEG/TIFF magic, or valid UTF-8; nothing over 512 KB
  is sniffed). No SQL box: use DB Browser for SQLite on the file via Open Data Folder.
- **Timings**: one bar chart per timing marker ("Open panel" today) of its last 20 durations, with the
  limit as a red line. Bars come from `Log.timing`, now a `TimingSignposter`: it still emits the
  `OSSignposter` intervals Instruments reads, and in debug builds also remembers the last 20 durations per
  name in memory. The sandbox gives an app no way to read its own signposts back (`OSLogStore` returns
  none), which is why they are remembered rather than read.
- **Logs**: this launch's log lines for the app's subsystem, newest first, with a category filter and a
  Refresh button. Read with `OSLogStore(scope: .currentProcessIdentifier)`, the one scope the sandbox
  allows; each read is a request to `logd` that takes 1–2 s of wall time (not our CPU), so the tab reads
  every 5 s, incrementally, on an actor. Only `.info` and above come back (the store never returns
  `.debug`), and private values show as `<private>`.

**The SQL trace.** In debug builds `Store` installs GRDB's `db.trace(options: .profile)` on every
connection and logs each statement with its duration to the `sql` category at `.info`. The SQL is the
statement as prepared, with `?` for the values, so clipboard contents never reach the log and it can be
`.public`. SQLite's profile clock has millisecond resolution, so "0 ms" means under one. A seed of 10,000
items logs about 100,000 lines in under a second; the Logs tab keeps only the last 500.

**How the window reads the database.** `StoreInspector` (ClipCore, `Storage/`) opens its own read-only
GRDB connection to the same file, so its queries never queue behind the app's and never appear in the SQL
trace. A read-only connection cannot use `ValueObservation` (it only sees its own connection's writes),
so the inspector asks `PRAGMA data_version`, SQLite's "did another connection commit?" counter, once a
second and re-reads only when it changed. The table list comes from `SELECT name FROM sqlite_master`,
because GRDB can describe a table it is given (`columns(in:)`) but has no call that lists them. Those are
the two raw SQL statements in the stage; the counts and pages are the query builder (`Table<Row>(name)`).

**Maintaining it.** To time something new, wrap it in `Log.timing.beginInterval("Name")` /
`endInterval("Name", state)` and it appears in Timings on its own; add its limit to `TimingsView.limits`
to get the red line (the "Search" entry is a guess at the name the search code will use). To show a new
number in Overview, add it to `StoreInspector.Snapshot` and one `LabeledContent` row. To change how many
rows per page, lines or durations are kept, edit `DatabaseView.pageSize`, `LogsView.keptLines` and
`TimingSignposter.keptPerName`. The Database tab needs no change for a new table or column; to preview a
new kind of blob, extend `StoreInspector.preview(of:)`. New Swift files need `xcodegen` again.

**Hand checks still open:**

- Open Developer… and copy a few things in another app: the Database tab's row counts and open page
  update and Overview's counts rise within a second.
- Database tab with `--seed 100000`: pick each table in turn, page to the last page of `clipboardItem`
  and `clipboardItemData`, and check paging feels instant; `cardThumbnail` rows show their PNG;
  `clipboardItemData` text rows show their text next to the size.
- Press ⇧⌘V a few times: the Timings tab shows a bar per open, all under the 50 ms line.
- Press Measure for 60 Seconds: the window disappears, comes back a minute later with a CPU and peak
  memory figure.
- Open Data Folder: Finder opens on `yank.sqlite` in the right folder (the seed folder when launched with
  `--seed`).
- Build the Release configuration and confirm the menu has no Developer… row.

## Sandbox and copied files (stage 0 spike)

Question: when the user copies a file in Finder, can the sandboxed app, reading the clipboard on a timer
rather than through a user paste, use that file?

| Check | Result |
| --- | --- |
| `fileExists` / read the file's bytes | Works. 10 KB PDF and 20 MB HEIC in `~/Dev`, read in full. |
| Quick Look thumbnail (`QLThumbnailGenerator`) | Works. 396×512 for the PDF, 512×512 for the HEIC. |
| Write the URL back to the clipboard | Works. Pasting it into a Finder folder: not yet checked by hand. |
| Drag the file from our window to the Desktop | Works, but Finder **moved** the file instead of copying it. |

The file URL was put on the clipboard by another process (`osascript`), not by Finder itself, because this
Mac's automation can't press ⌘C in Finder. A file outside the container was readable anyway, so reading
the URL from the clipboard appears to give the app access to that file. The hand check of a real Finder ⌘C
was inconclusive (screen sharing replaced the clipboard with text); the stage 1 hand check repeats it.

**Decisions:**

- A file item stores the file's path, not a security-scoped bookmark. Revisit only if a real Finder copy
  in stage 1 can't be read.
- Dragging a card out (stage 8) must offer only the copy operation, so it never moves the user's file.
