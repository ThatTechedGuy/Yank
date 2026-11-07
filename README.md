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
| `App/` | The app target: windows, menu bar, panel. May import ClipCore, ClipSystem, SwiftUI, AppKit, KeyboardShortcuts. |
| `App/Resources/Assets.xcassets` | The app icon, `AppIcon` (10 PNG slots, 16 to 1024 px). The menu bar uses the SF Symbol `list.clipboard` instead. Masters and a `build.py` that regenerates the PNGs are in `~/Downloads/Yank-icons/source`, not in the repo. |
| `Packages/ClipCore/Sources/ClipCore` | Model, rules, storage, services, ports. Foundation, CryptoKit, os only; GRDB only in `Storage/`. |
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
scripts/test.sh --fast   # import check + package tests, a few seconds, no app launch
scripts/test.sh          # also the UI tests; quits a running Yank first and reopens it after
```

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

The content is a search field (empty for now, the search itself comes later), a horizontal `LazyHStack`
of `ItemCard`s inside a `ScrollView`, and `PanelModel`, an `@Observable` class (≈ a store in Zustand or a
ViewModel) that owns the list and the selected item. The list is one live GRDB query,
`Store.observeItems(limit:)` (a `ValueObservation`): the database tells the model when rows change, so a
new copy appears on the strip while it is open. Paging is "one growing query": the model starts with 200
items and, when a card near the end appears on screen (`cardDidAppear`), raises the limit by 200 and
restarts the query. Hiding the panel resets the limit and the selection. ←/→ move the selection, Tab
toggles between the search field and the row, ⌘1–⌘9 are shown in the footers (they do nothing until paste
exists). Cards show the kind (SF Symbol + label), the text or a description, a relative time
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
