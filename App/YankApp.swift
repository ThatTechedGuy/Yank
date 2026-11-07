// The app's entry point. Everything the user sees starts here.
//
// ClipCore is our own package module (logging, and later rules and storage).
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
// This target uses "default actor isolation: MainActor" (see project.yml), so everything in this
// file runs on the main thread, Android's UI thread, without having to say so.
@main
struct YankApp: App {
    // `init()` is the initializer, ≈ a constructor. SwiftUI creates YankApp once at launch.
    init() {
        // Visible in Console.app under subsystem com.thattechedguy.Yank, category "ui".
        Log.ui.info("Yank launched")
    }

    // `var body: some Scene { ... }` is a computed property: code that runs whenever SwiftUI
    // reads `body`, like a React component's render. `some Scene` means "one specific Scene
    // type that the compiler works out", so we don't have to spell the long generic type.
    //
    // A Scene is a top-level piece of UI: a window, the Settings window, or a menu bar item.
    // ≈ the screens registered at the root of a React Navigation tree.
    var body: some Scene {
        // MenuBarExtra puts an icon in the menu bar (top-right of the screen) with a menu under it.
        // "list.clipboard" names an SF Symbol, Apple's built-in icon set (≈ a vector icon font
        // like @expo/vector-icons; browse them with the free SF Symbols app).
        //
        // The `{ ... }` after the parentheses is a trailing closure: the last argument is a
        // function, written outside the call. ≈ passing `children` in JSX.
        MenuBarExtra("Yank", systemImage: "list.clipboard") {
            // A Button takes a title and an action closure (≈ onPress).
            // NSApplication is AppKit's object for the running app; terminate(nil) quits it.
            // `nil` is Swift's null; here it means "no sender".
            Button("Quit Yank") { NSApplication.shared.terminate(nil) }
                // A view modifier: wraps the button to add ⌘Q while the menu is open.
                // Modifiers chain like styled-components or RN style props, returning new views.
                .keyboardShortcut("q")
        }
    }
}
