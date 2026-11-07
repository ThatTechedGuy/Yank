// The app's entry point: it creates the one AppModel and puts Yank's icon and menu in the menu bar.
// Everything the user sees starts here.
//
// ClipCore is our own package module; this file only needs its `Log`.
// SwiftUI is Apple's declarative UI framework. ≈ React / React Native: you describe the UI as a
// function of state, and SwiftUI re-renders when that state changes.
import ClipCore
import SwiftUI

// `@main` marks the program's entry point. ≈ `"main"` in package.json, or the launcher Activity
// in AndroidManifest.xml. There is no `main()` to write: SwiftUI runs the app's event loop.
//
// `struct YankApp: App` declares a struct that conforms to the `App` protocol. A protocol is an
// interface (≈ `implements App` in TS/Java). Conforming to App means providing a `body`.
//
// project.yml sets SWIFT_DEFAULT_ACTOR_ISOLATION to MainActor for this target, which means
// everything in this file runs on the main thread (Android's UI thread) without having to say so.
@main
struct YankApp: App {
    // The one AppModel for the whole app. `@State` makes SwiftUI create it once and keep it alive
    // for the life of the app, so it is not rebuilt each time `body` re-renders and the database is
    // not reopened. ≈ `useState`, or a ViewModel scoped to the Activity. `private` because only
    // this struct creates it; views below get it as a plain argument.
    @State private var model = AppModel()

    // Runs once at launch, before any UI exists. (`init()` is the initializer, ≈ a constructor.)
    init() {
        // Log the launch so you can confirm the app started. Visible in Console.app under
        // subsystem com.thattechedguy.Yank, category "ui".
        Log.ui.info("Yank launched")
    }

    // `body` describes the whole UI: for Yank, a single menu bar item. SwiftUI reads it again
    // whenever something it used in `model` changes, like a React component's render. (`var body:
    // some Scene { ... }` is a computed property; `some Scene` means "one specific Scene type that
    // the compiler works out", so we don't have to spell the long generic type.)
    //
    // A Scene is a top-level piece of UI: a window, the Settings window, or a menu bar item.
    // ≈ the screens registered at the root of a React Navigation tree.
    var body: some Scene {
        // MenuBarExtra puts an icon in the menu bar (top-right of the screen) with a menu under it.
        // It is Yank's whole UI, because the app has no Dock icon and no windows (LSUIElement in
        // project.yml). "list.clipboard" names an SF Symbol, Apple's built-in icon set (≈ a vector
        // icon font like @expo/vector-icons; browse them with the free SF Symbols app). Symbols
        // are drawn as *template* images: macOS keeps only the shape and paints it black, white
        // or the accent colour to match a light, dark or tinted menu bar, so it always fits in.
        //
        // The `{ ... }` after the parentheses is a trailing closure: the last argument is a
        // function, written outside the call. ≈ passing `children` in JSX.
        MenuBarExtra("Yank", systemImage: "list.clipboard") {
            // First row: the saved count, or the error if the database did not open. SwiftUI
            // re-renders these rows when `model` changes (it is @Observable). They are `Text`, a
            // plain label, because a `Button` with no action would look clickable and do nothing.
            if let error = model.startupError {
                Text(error)
            } else {
                // "1 item saved", "2 items saved": `^[...](inflect: true)` asks Foundation to pick
                // the singular or plural for the number in the sentence.
                Text("^[\(model.itemCount) items](inflect: true) saved")
            }
            // Rows that explain why nothing is being saved, with a button to fix it. macOS (15.4+)
            // can ask the user before every clipboard read, or refuse it; the model re-reads that
            // state on every poll, so these rows appear and disappear as the user changes it.
            // `switch` over an enum must cover every case; `.allowed` needs no row, so it shows an
            // EmptyView.
            switch model.clipboardAccess {
            case .allowed:
                EmptyView()
            case .askEachTime:
                Text("macOS asks before every copy.")
                Button("Allow Yank in System Settings…") { model.openClipboardSettings() }
            case .denied:
                Text("Clipboard access is off, so nothing is saved.")
                Button("Allow Yank in System Settings…") { model.openClipboardSettings() }
            }
            Divider()
            // Debug builds only: "Developer…" opens the Developer window and "Open Data Folder"
            // shows the database in Finder. The compiler leaves both out of a release build.
            #if DEBUG
                DeveloperMenuItems(model: model)
                Divider()
            #endif
            // The only way to quit Yank: with no Dock icon and no app menu, there is no other Quit.
            // A Button takes a title and an action closure (≈ onPress). NSApplication is AppKit's
            // object for the running app; terminate(nil) quits it. `nil` is Swift's null; here it
            // means "no sender".
            Button("Quit Yank") { NSApplication.shared.terminate(nil) }
                // Lets ⌘Q quit while the menu is open, as users expect from any Mac app. This is a
                // view modifier: it wraps the button and returns a new view. Modifiers chain like
                // styled-components or RN style props.
                .keyboardShortcut("q")
        }
        // The Developer window, a second scene that exists only in debug builds. Declaring it
        // here does not open it: the menu item above does, by its id.
        #if DEBUG
            DeveloperWindow(model: model)
        #endif
    }
}
