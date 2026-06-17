# #2 — MenuBarExtra observation staleness

The menu bar shows a stale string forever (classic: stuck on "Starting up…") and never
reflects live app state, even though the underlying state object is updating correctly.
**No community skill covers this** — the "menu-bar" skills that exist are about the
top-of-screen application menu (`.commands` / `CommandMenu`), a different API surface.
This is **[ours]**, end to end.

It is almost always **two independent bugs stacked**, and fixing only one leaves it stale.

## Bug layer A — `.menu` style builds its `NSMenu` once

`MenuBarExtra` has two styles:

| Style | What it is | Live re-render? |
|---|---|---|
| `.menu` (default) | A native `NSMenu` dropdown | **No** — built once when the menu opens; SwiftUI does not re-evaluate it as state changes |
| `.window` | A popover panel hosting a live SwiftUI view | **Yes** — observes `@Published`/`@Observable` like any SwiftUI view |

If your status text must update live, you need `.window`:

```swift
MenuBarExtra { rootView } label: {
    Image(systemName: "brain.head.profile").help("ADHD Companion")  // .help = hover tooltip (easy to forget)
}
.menuBarExtraStyle(.window)   // ← without this, the popover content is built once and frozen
```

> Sub-gotcha: the hover **tooltip** (the name shown on mouse-over) is *not* automatic — set
> `.help("…")` on the label's `Image`. A missing tooltip is a separate, commonly-missed
> defect.

## Bug layer B — the observation dependency is never established

Switching to `.window` is necessary but **not sufficient**. SwiftUI only re-renders a view
when it reads observable state **through a tracked graph node**. Reading `@Published`
state off an `@NSApplicationDelegateAdaptor` object does **not** establish that
dependency — the adaptor is an injection seam, not an observation root — so the view reads
the value once and never updates.

```swift
// ❌ STALE — reading @Published off the delegate adaptor establishes no dependency
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        MenuBarExtra { Text(delegate.coordinator?.statusLine ?? "Starting up…") } // never updates
            label: { Image(systemName: "brain.head.profile") }
    }
}
```

The fix is an **owned model held by a tracked node** (`@StateObject` for the
`ObservableObject` era, or `@State` for an `@Observable`), which the delegate *writes into*:

```swift
// AppModel.swift  — the observation root, owned by the scene
@MainActor public final class AppModel: ObservableObject {
    public static let shared = AppModel()
    @Published public var coordinator: Coordinator?     // delegate writes here
    @Published public var startupError: String?
}

// App.swift — @StateObject makes AppModel a tracked graph node
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            rootView          // reads model.coordinator / model.startupError → live updates
        } label: { Image(systemName: "brain.head.profile").help("ADHD Companion") }
        .menuBarExtraStyle(.window)
    }
}

// AppDelegate.swift — no longer the observation root; it writes into AppModel.shared
final class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: Coordinator? {
        get { AppModel.shared.coordinator }
        set { AppModel.shared.coordinator = newValue }
    }
}
```

## The mental model (general, but apply it to the menu-bar case)

- **Ownership vs injection** [mined — `avdlee/swiftui-expert › state-management.md`]:
  `@StateObject` when the view **creates and owns** the object; `@ObservedObject` when it
  **receives** it. For `@Observable`: hold an owned instance with `@State`, *never* `let`
  (without `@State`, SwiftUI may recreate it on parent redraw and lose state).
- **A change to any `@Published` notifies all observers; a view updates only for the
  properties it actually reads** — so reading through the tracked node is what matters.

## Currency note [mined — affaan/avdlee/twostraws]

The community consensus is that `@StateObject`/`ObservableObject`/`@Published` are the
**legacy** path and new code should use `@Observable` + `@State` + `@Environment(_:)`. The
*principle above is identical either way*: the model must be **owned by a tracked graph
node in a `.window` scene**. If you migrate this app to `@Observable`, hold the root model
with `@State` at the scene and inject it with `@Environment(AppModel.self)`; do **not**
read it off the delegate adaptor.

## Verify on the running binary

- Launch; trigger a state change (connect/disconnect/error); confirm the menu text changes
  **without reopening** the popover. Screenshots of the live menu are the decisive evidence
  — this bug cannot be seen in a build log or a unit test.
- Hover the icon → the `.help` tooltip name appears.

## Checklist

- [ ] `.menuBarExtraStyle(.window)` if the content must update live.
- [ ] The displayed model is owned by `@StateObject`/`@State` at the scene, **not** read
      off the `@NSApplicationDelegateAdaptor`.
- [ ] The delegate *writes into* the shared model; it is not the observation root.
- [ ] `.help("…")` set on the label image for the hover tooltip.
- [ ] Live-verified with a real state transition (and a screenshot).
