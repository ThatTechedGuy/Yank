# Yank

A Paste-style clipboard manager for macOS 26.4 and later. Menu bar only, sandboxed, no sync. The full
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
| `App/Resources/Assets.xcassets` | The app icon, `AppIcon` (10 PNG slots, 16 to 1024 px). The menu bar uses the SF Symbol `list.clipboard` instead (`pause.circle` while saving is paused). Masters and a `build.py` that regenerates the PNGs are in `~/Downloads/Yank-icons/source`, not in the repo. |
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
(`activeApp` / `clipboardOnly`) and `alwaysPlainText`, named in `SettingsKey`. The Settings window's
General tab edits the same keys with `@AppStorage`, which is SwiftUI's view wrapper over the same store.
They can also be set for one run from the command line, because macOS lets any `-key value` launch
argument override a default:
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
what "plain text" keeps, edit the filter in `PasteService.paste`. A new setting gets its key in
`SettingsKey`, a reader in `PasteSettings`, and the service gets it as a parameter, so ClipCore never
reads `UserDefaults`. If a layout
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

## Settings, menu bar and privacy (stage 6)

The menu under the icon has, besides the count and Quit: Open Panel (with the user's shortcut next to
it), Pause Saving (15 minutes, 1 hour, until resumed; while paused the row says "Paused until 3:45 PM"
or "Paused", the icon is `pause.circle` and the row is Resume Saving) and Settings… (⌘,). The Settings
window has three tabs: General (open at login, where pastes go, always plain text, the panel shortcut),
Privacy (the ignored apps, and whether the panel shows up in screen recordings) and Data (the count and
Erase History…). ⌘, inside the panel opens it too.

**How a setting works.** Every setting is one key in `UserDefaults`, named once in `SettingsKey`
(`App/Features/Settings/SettingsKeys.swift`). The window (`SettingsView`) binds each control with
`@AppStorage`, so a change is on disk at once and there is no save button; the code that acts on it
reads the same key: `PanelWindow.show` reads `showPanelInScreenSharing` into the window's `sharingType`
on every open, and the paste code reads `pasteDestination` and `alwaysPlainText`. The ignored apps are
one JSON list of bundle ids under `ignoredApps` (`IgnoredApps`, a `RawRepresentable` so `@AppStorage`
can hold it); `AppModel.watchIgnoredApps` copies it into `CaptureService.rules.ignoredApps` at launch
and on every `UserDefaults.didChangeNotification`, because ClipCore never reads `UserDefaults`. Any key
can be overridden for one run with `-key value` on the command line.

**Open at login** is not a setting Yank stores: macOS keeps it (System Settings › General › Login
Items), so the General tab reads `SMAppService.mainApp.status` when it appears and after each toggle,
and calls `register()` or `unregister()`. If macOS answers `.requiresApproval`, the toggle shows off
with a line saying where to allow it. The Settings window itself is SwiftUI's `Settings` scene in
`YankApp`; `SettingsLink` in the menu and `openSettings` from the panel open it, and `AppModel.openSettings`
hides the panel and activates the app first, so the window comes to the front.

**Pause** is `PauseState` in ClipCore (`.running`, `.pausedUntil(Date)`, `.pausedUntilResumed`), a
value with no clock inside: `isPaused(at:)` compares with the time passed in. `AppModel` keeps the
current one and passes every change to `CaptureService.pause`; the capture tick marks the change count
as handled and returns without reading the clipboard while paused, so a copy made during a pause is
never saved, not even afterwards. The poll loop notices a timed pause ending and resets the icon. A
pause is not saved to disk: quitting resumes.

**Erase History** is `Store.eraseHistory`: one transaction deletes every item with no pinboard (data
rows and thumbnails go by cascade), then the files, then `VACUUM` and a WAL checkpoint so the file on
disk shrinks right away. Pinned items stay. The panel follows the database on its own; the menu's count
is re-read when it is done.

**Maintaining it.** To add a setting: a key in `SettingsKey`, a control in the right tab bound with
`@AppStorage(SettingsKey.x)`, and a read of the same key where it takes effect; nothing else, and no
migration, since missing keys fall back to the control's default. To add a menu row, edit
`MenuBarContent`. To change the pause lengths, edit `pauseRows` there. The ignored-apps rows live in
`IgnoredAppsList`; the Open dialog it shows is a sheet (`beginSheetModal`), not `runModal`, because a
modal run loop from a menu bar app closed the dialog on its own after a few seconds. ClipCore stays free
of `UserDefaults` and AppKit: settings cross into it as plain values (`rules`, `pause`).

**Hand checks still open:**

- General › Open at login: switch it on, check Yank appears in System Settings › General › Login Items,
  log out and in: Yank is running; switch it off and check it is gone from the list.
- Add an app to Ignored apps, copy something in it: nothing is saved and the menu count stays; remove
  it and copy again: it is saved.
- Copy something in 1Password (or any app that marks its copies as private): it is not saved, with or
  without the ignored list.
- Pause for 15 minutes, copy, wait, resume: the copy was not saved, and the icon shows the pause sign
  only while paused. Quit while paused and relaunch: saving is on again.
- With "Show the panel in screen recordings" off, start a QuickTime screen recording or share the
  screen in a call and open the panel: it is not in the recording. Switch it on, reopen the panel: it
  is.
- Erase History with a pinned item (pin one with the developer tools or the database): the pinned one
  stays, everything else goes, and the database file on disk is small.
- Change the panel shortcut in General: the new key opens the panel at once and the menu row shows it.

## Pinboards and filters (stage 7)

Under the search box sits a tab row: History, then one tab per pinboard, then "+". A pinboard is a named
list of items to keep ("Snippets", "Work"); an item sits on at most one, so pinning moves its card from
History to that tab, and "Erase History" erases exactly the History tab. ⌘[ and ⌘] move one tab left or
right, round and round; ⌘P pins the selected card (to the one pinboard if there is one, through a small
chooser if there are several, after asking for a name if there is none) or unpins it when it is already
pinned. Right-clicking a card offers the same. Right-clicking a pinboard's tab offers Rename… and Delete…;
Delete asks first, and the items go back to History. The filter button at the right of the row narrows
the cards by type (Text, Image, Link, File, Color) and date (Today, Last 7 Days, Last 30 Days, Any Time);
its icon fills in while anything is narrowed, and Clear Filters resets both. Filters, the tab and the
search all combine, and the tab and filter stay as they were when the panel reopens.

**How the lists work.** `ItemFilter` (`Packages/ClipCore/Sources/ClipCore/Rules/ItemFilter.swift`) is
one value with the list (`.history` or `.pinboard(id:)`), the kind and the `DateRange`. The Store's live
list, `observeItems(matching:limit:)`, and `search(_:matching:limit:)` both take it and both build their
query with `ClipboardItem.matching` in `Storage/Records.swift`: one `WHERE` clause per part of the filter
(`pinboardId IS NULL` or `= ?`, `kind = ?`, `copiedAt >= ?`). The panel keeps the filter in
`PanelModel.filter`; setting it restarts the live list and the search (`didSet`), so the tabs, the menu
and the keys all just write that one property. The pinboards themselves come from a second live query,
`observePinboards`, so a tab appears, renames or vanishes the moment the database changes; if the tab
the panel is on is deleted, the model falls back to History.

**Dates.** `DateRange.start(now:calendar:)` is a pure function: "today" is `calendar.startOfDay(for: now)`,
local midnight; the longer ranges step back whole days with `date(byAdding: .day, value: -6)` (and
`-29`), so today is one of the seven or thirty days and the day the clocks change is still one day, not
24 hours. The Store passes `Date()` and `Calendar.current`; the tests pass a fixed clock and other time
zones. The start is worked out once when the query starts, so a panel left open across midnight keeps
yesterday's "today" until the filter or the panel changes.

**Pinning.** `Store.pin(itemId:to:)` sets the item's `pinboardId` (a missing pinboard is a quiet no-op,
in case it was deleted a moment earlier); `unpin` clears it. `deletePinboard` only deletes the row: the
foreign key is `ON DELETE SET NULL`, so SQLite returns the items to History in the same statement. A
repeat copy of a pinned item keeps its pinboard (the save reuses the existing row). Pinboards are
ordered by `position`, which is creation order; there is no reordering.

**The panel's side.** `PanelModel+Pinboards.swift` holds the actions (`selectNextTab`, `togglePin`,
`pin`, `unpin`, `createPinboard`, `renamePinboard`, `deletePinboard`), each one Store call in a Task;
the live queries deliver the result, the model never patches its own lists. `PanelTabs` is the tab row
with its prompts, `FilterMenu` the button and menu (and the user-facing names of kinds and ranges),
`PinChoices` the Pin to…/Unpin rows that serve both the card's right-click menu and the ⌘P chooser. The
prompts are popovers, not alert sheets: the panel is a non-activating window, and popovers are the one
dialog proven to take typing on it without activating Yank.

**Maintaining it.** To add a filter: a property on `ItemFilter`, one `filter(...)` line in
`ClipboardItem.matching`, a control in `FilterMenu`, and include it in `isNarrowed` if it should tint the
button. To add a date range: a case in `DateRange` and its name in `FilterMenu`; the menu lists
`allCases`. To add a pinboard action: a Store method, a model method next to the others, and a row in
`PanelTabs`' context menu or `PinChoices`. Keys live in `PanelView` next to ⌘,: the same
`onKeyPress(.init("x"), phases: .down)` with a `press.modifiers == .command` guard. The seed
(`Store.seed`) clears pinboards too, so every UI test starts on a plain History tab.

**Hand checks still open:**

- Create "Snippets" with "+", pin a card with right-click or ⌘P: it is on the Snippets tab and gone from
  History. ⌘[ and ⌘] move between the tabs and wrap around.
- Rename it from the tab's menu, then Delete it: the app asks first, and after Delete the card is back in
  History.
- Pin a card, then Settings › Data › Erase History: the pinned card is still on its tab, History is empty.
- Filter Image + Last 7 Days: only images from the past week; the button's icon is filled. Clear Filters:
  the full list is back. Type in search with a filter on: results respect both.
- Copy something already pinned: it moves to the top of its pinboard, not into History.

## Actions, selecting several, dragging and the paste stack (stage 8)

Right-click a card, or press ⌘K on the selected one, for its actions: Paste, Paste as Plain Text, Copy,
Pin to… (or Unpin), Add to Stack, Edit (greyed out until there is an editor), Rename…, Duplicate, Share…,
Open With, Show in Finder (file cards only) and Delete…. The right-click menu is a real macOS menu; ⌘K
opens the same rows as a list above the card that ↑ ↓ walk and Return fires. Several cards can be
selected: ⌘-click adds one, ⇧← and ⇧→ grow the selection one card at a time, ⌘A takes them all. The
lead card (the one the keys move from) has the full accent outline, the others a fainter one. Return,
⌘K's actions, ⌫ and a drag all act on the whole selection. Dragging a card into another app carries
every type that was saved, so TextEdit gets the text and the Desktop gets the file; dragging a selected
card takes the selection. Drags only ever copy. A file card whose file has since been deleted says
"File no longer exists" and refuses to paste or drag. The paste stack lives in the menu bar: Turn Paste
Stack On, then every copy joins a queue, the icon shows how many are waiting, and ⌃⌥⌘V pastes the oldest
into the app in front and takes it off; Turn Paste Stack Off drops the queue (the items stay in History).

**Selection.** `CardSelection` (`Packages/ClipCore/Sources/ClipCore/Rules/CardSelection.swift`) is a
value: the `lead`, the `anchor` the ⇧ keys stretch from, and the set of `ids`. `select` picks one,
`extend(by:in:)` moves the lead one step along the row's order and selects every card between the anchor
and it, `toggle` is ⌘-click, `selectAll(in:)` and `keep(in:)` (drop ids that left the list) take the
row's order. `PanelModel.selection` holds one; `selectedId` is still the lead, for the keys and the
preview, and `selectedItems` is the selection in row order. The live list calls `keep` on every update,
so a deleted card leaves the selection by itself.

**Actions.** `ItemAction` (`App/Features/Panel/PanelModel+Actions.swift`) is the list of rows, in menu
order, with `available(for:)` dropping Show in Finder for anything but a file. `PanelModel.perform(_:on:)`
runs one; when the card is in the selection, the action takes the whole selection. The rows are drawn by
`ItemActionRow` in `App/Features/Actions/ItemActionsMenu.swift`, once for the `.contextMenu` and once for
the ⌘K `List`; Share… is a `ShareLink` of a `ShareableItem` (`Transferable`: text as UTF-8, an image or
file as the Quick Look file), Open With asks `NSWorkspace` which apps open the card's type. `CardPrompt`
is the one popover open on a card: the ⌘K list, the Rename box or the Delete question; `PanelModel.prompt`
holds it and the card it is anchored to, and changing the selection closes it.

**Multi-paste.** `PasteService.paste(_ items:...)` writes one pasteboard item per card, in row order,
and presses ⌘V once; the app in front decides what to do with several (TextEdit joins the texts, Finder
takes every file). The Store's `moveToTop(ids:)` bumps them all, so repeat-copy ordering still holds.
Before writing, the service checks every file card's file is still there and throws
`PasteError.fileNoLongerExists`; the model catches that and marks the card.

**Dragging.** `CardDrag` (`App/Features/Panel/CardDrag.swift`) is an AppKit `NSDraggingSession` started
from a `DragGesture`, not SwiftUI's `.draggable`: only an AppKit drag source can insist on copy, and
without that Finder moved the file. The state is an enum: `idle`, `loading` (reading the cards' data off
the main thread after the first pointer move), `ready` with the pasteboard items, `dragging`. The session
starts from an invisible AppKit view behind the card, with a bitmap of the card as the drag image.

**The stack.** `PasteStack` (`Rules/PasteStack.swift`) is an enum, `.off` or `.on(queue:)`, with
`turnOn`, `turnOff`, `add` (ignored while off) and `popNext`. `AppModel` keeps one; `CaptureService`'s
`onCapture` adds every new copy (the app's own pastes never reach it, so pasting from the stack cannot
feed it), ⌃⌥⌘V (`ShortcutNames.pasteNext`) pops and pastes through the same `PasteService` with the
user's paste settings, and `MenuBarContent` shows the state. Add to Stack in a card's menu turns the
stack on if it was off.

**Maintaining it.** To add an action: a case in `ItemAction` (position in the enum is position in the
menu; `startsGroup` draws a separator above it), its title, and a branch in `PanelModel.perform` or, if
it needs its own control, a case in `ItemActionRow`. To change a key: `PanelView`, next to the others.
To change what a drag carries: `SystemClipboard.pasteboardItems(for:)` builds the items for both paste
and drag. The stack's shortcut defaults live in `ShortcutNames`.

**Hand checks still open:**

- Right-click a text card: the menu lists the actions above; Show in Finder appears only on a file card.
  ⌘K on the selected card: the same rows above it; ↓ ↓ Return runs the highlighted one; Esc closes it.
- Rename a card: its card and the search find the new name. Duplicate: a copy appears at the top and
  is selected. Delete with ⌘⌫: the app asks; Delete removes it.
- ⌘-click two cards, then ⇧→ a third: three outlined, the lead brightest. Return pastes all three into
  TextEdit, in row order. ⌫ asks "Delete 3 items?".
- Drag a text card into TextEdit, an image into Preview or Keynote, a file onto the Desktop: each lands,
  and the file is copied, not moved. Drag with two cards selected: both land.
- Copy a file, delete it in Finder, open the panel: the card says "File no longer exists"; Return and a
  drag do nothing to the other app.
- Menu bar › Turn Paste Stack On, copy three things: the icon shows 3 and the menu lists them. In
  TextEdit, ⌃⌥⌘V three times: they paste oldest first and the count falls to 0. Turn it off: the
  count goes; the three are still in History.
- Share… on a text card opens the share sheet with the text; on an image, with the picture.

## Text in images and link previews (stage 9)

Copy a screenshot and, a few seconds later, search for a word that is only in the picture: the card is
found. Copy a web address and the card turns into a bookmark: the site's icon, the page's title in bold,
the address underneath; the title is searchable too. Settings › Privacy › Link previews turns the fetch
off (the switch's text says why you might: opening a one-time link uses it up). Nothing is ever fetched
for an address on this Mac or the local network, whatever the switch says. The minimum macOS is 26.4
from this stage on, for `LinkMetadata`.

**Reading text.** `TextRecognizer` (`Packages/ClipCore/Sources/ClipSystem/TextRecognizer.swift`) runs
Vision's `RecognizeTextRequest` on the copy's first image type, `.accurate`, with language correction and
per-image language detection, and joins the recognised lines with newlines. It runs on the Mac; nothing
leaves it. `Enricher.recognizeText(in:)` calls it after `enrich` (the thumbnail must not wait the second
or so the model takes) and saves the words in the item's `imageText` column, which the search index has
covered since stage 4, so the GRDB sync triggers index them on that write. `enrichInBackground`, the
capture path's call, does both steps in order.

**Fetching a link.** `LinkFetching` (`ClipCore/Ports/LinkFetching.swift`) is the port: `fetch(URL) async
throws -> LinkPreview` (title, icon as a card-sized PNG). `LinkFetcher` (`ClipSystem/LinkFetcher.swift`)
is the real one: `LinkMetadata(fetching:timeout:includeSubresources:)` from LinkPresentation loads the
page the way Safari would (so a title written by JavaScript still comes through), `media(.icon, as:
Data.self)` gives the icon in whatever format the site serves, and `Thumbnailer.imageThumbnail` turns it
into a PNG. The ten-second `timeout` is the API's; an address that swallows the connection instead of
refusing it took a minute in testing, which is the `shortcut:` comment in the file. In `Enricher`, a
link is fetched only if `linkPreviewsEnabled()` says yes (the app passes a closure that reads the
UserDefaults key, so ClipCore never reads defaults itself) and `LocalAddress.isLocal(url)` says no; a
skipped local address logs "skipped: local address". The icon is saved as the item's `cardThumbnail`
row and the title in `linkPageTitle` (`Store.setPreview`, one transaction). The in-flight table from
stage 5 means a link is fetched once however many cards ask.

**Local addresses.** `LocalAddress` (`ClipCore/Rules/LocalAddress.swift`) is a pure function over the
URL's host: `localhost` and `*.localhost`, `*.local`, and by number (parsed with `inet_pton`) 0/8, 10/8,
127/8, 169.254/16, 172.16/12, 192.168/16, IPv6 `::`/`::1`, fc00::/7, fe80::/10 and an IPv4 address
carried as `::ffff:a.b.c.d`. A URL with no host counts as local. Known limit, as the `shortcut:` comment
says: a public name that resolves to a local address, or a public page that redirects to one, is still
fetched; the check sees only the address as written.

**On screen.** `ThumbnailCache.image(for:)` now loads for `.link` too, so a link card gets its icon the
same way an image gets its thumbnail. `ItemCard` has a link branch: icon (32 pt, rounded), then the
renamed title or `linkPageTitle` in semibold with the address in a caption below; with no title yet
(fetch pending, previews off, local address), the address alone as before.

**Settings.** `SettingsKey.linkPreviews`, a Bool that is on when missing, so `SettingsKey.
linkPreviewsEnabled` (not `bool(forKey:)`, which reads a missing key as off) is what `AppModel` hands
the Enricher. The Toggle is in `PrivacySettings`, identifier `link-previews`. Like every other setting,
`-linkPreviews NO` on the command line turns it off for one run.

**Tests.** `LocalAddressTests` (`RulesTests.swift`): nineteen local and eleven public addresses, both
sides of every boundary (172.15 vs 172.16, 172.31 vs 172.32, 192.168 vs 192.169, 127 vs 11, `[::1]`,
`[fd00::1]`, `[fe80::1%en0]`, `::ffff:` forms, `.local` vs `.localdomain`). `EnricherTests` with
`FakeLinkFetcher` (records every address it is asked for): a public link is fetched once and its title
is searchable and its icon is the thumbnail; nothing is fetched while previews are off; a local address
is never fetched, copied as a URL type or as plain text; a text with addresses in it is not fetched; and
a fake recognizer's words land in the search index. `TextRecognizerTests` (ClipSystemTests) draws a
sentence into a PNG, saves it as an image copy and finds it by one of its words through real Vision,
the Store and the Enricher; its name starts with `slow` because Vision's first model load takes tens of
seconds, so `test.sh --fast` skips it.

**Maintaining it.** To block another address range: a line in `LocalAddress.isLocalIPv4` or
`isLocalIPv6`, and a case on each side of the boundary in `LocalAddressTests`. To change what a link
card shows: the `.link` branch of `ItemCard.content`. To fetch more from a page (a description, a hero
image): a field on `LinkPreview`, filled in `LinkFetcher.fetch` from `LinkMetadata`, and a column plus
migration if it should be stored. To change how text is read (fast mode, a fixed language): the request
setup in `TextRecognizer.text(in:)`. To add a setting the core must see, follow `linkPreviewsEnabled`:
a key in `SettingsKey`, a `@AppStorage` Toggle, and a closure passed in from `AppModel`.

**Hand checks still open:**

- Fresh install, copy `https://www.apple.com`: within seconds the card says "Apple" with the Apple icon,
  and searching "apple" finds it.
- Copy `http://192.168.1.1/` and `http://localhost:8080/`: the cards stay as addresses, and
  `log stream --predicate 'subsystem == "com.thattechedguy.Yank"' --info` shows "skipped: local address".
- Previews off, copy a new link: address only, and no request in Little Snitch or the log. Back on, the
  next copied link gets its title.
- Copy a screenshot of a web page, wait ~10 s, search a word that is only in the picture: found. Delete
  the item and search the word in Spotlight: nothing from Yank.
- Copy an image with no text (a photo): the card still gets its thumbnail; nothing else changes.

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
