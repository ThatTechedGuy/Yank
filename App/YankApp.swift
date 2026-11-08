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

    // `body` describes the whole UI: the menu bar item, the Settings window and the welcome
    // window. SwiftUI reads it again whenever something it used in `model` changes, like a React
    // component's render. (`var body: some Scene { ... }` is a computed property; `some Scene`
    // means "one specific Scene type that the compiler works out", so we don't have to spell the
    // long generic type.)
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
        // function, written outside the call. ≈ passing `children` in JSX. The icon swaps to a
        // pause sign while saving is paused, so the state is visible without opening the menu,
        // and the number of items waiting in the paste stack sits next to it while there are
        // any (the badge from the paste stack's picture).
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            let waiting = model.stack.queue.count
            Label {
                Text(waiting > 0 ? "\(waiting)" : "")
            } icon: {
                Image(systemName: model.isPaused ? "pause.circle" : "list.clipboard")
            }
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("Yank")
        }
        // The Settings window. SwiftUI owns it: the scene gives us the window, ⌘, from the
        // menu, and `SettingsLink` to open it from anywhere. It is built the first time it is
        // opened. `.environment(model)` hands the model to the views inside, the way a React
        // context provider does, so the Data tab can erase the history and show the count.
        Settings {
            SettingsView()
                .environment(model)
        }
        // The Format menu's Bold, Italic and Underline (⌘B ⌘I ⌘U), which the editor's rich
        // text box answers to. Yank shows no menu bar of its own, but the keys still reach a
        // hidden menu's commands while one of Yank's windows has the keyboard, so the editor
        // gets them without a menu anyone sees.
        .commands { TextFormattingCommands() }
        // The welcome window: one window (a `Window` scene, unlike a `WindowGroup`, never has
        // a second copy) that opens by itself on the first launch and never again.
        // `defaultLaunchBehavior` is SwiftUI's switch for "open this scene at launch or not";
        // it is read once, when the app starts, from the setting the window writes when it
        // appears. `restorationBehavior(.disabled)` stops macOS from reopening it after a
        // quit, which it would otherwise do for any window left open. `contentSize` makes the
        // window exactly as big as its content, with no resizing.
        Window("Welcome to Yank", id: "welcome") {
            WelcomeView()
                .environment(model)
        }
        .defaultLaunchBehavior(
            UserDefaults.standard.bool(forKey: SettingsKey.hasShownWelcome) ? .suppressed : .presented
        )
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
        // The Developer window, a second scene that exists only in debug builds. Declaring it
        // here does not open it: the "Developer…" row in MenuBarContent does, by its id.
        #if DEBUG
            DeveloperWindow(model: model)
        #endif
    }
}
