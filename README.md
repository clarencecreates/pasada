# Widyip

An offline-first iPhone app that turns a personal message into a jeepney-inspired Home Screen widget.

## What is built

- Placard library: a card carousel. Swipe to browse, drag a placard down into the slot to equip it as the widget, drag up to delete (with undo). The last card starts a new placard.
- Canvas editor: text and image layers with move, corner scale, pinch, rotate, curved text and per-line fonts. Every change autosaves.
- Native WidgetKit extension (medium) that renders with the same `SignRenderer` as the app.
- App-authored templates: versioned JSON (`PlacardTemplate`), importable from the template picker or bundled in `Resources/Templates`.

## Identifiers

| | |
|---|---|
| App bundle ID | `com.cyrillepardinas.widyip` |
| Widget bundle ID | `com.cyrillepardinas.widyip.WidyipWidget` |
| App Group | `group.com.cyrillepardinas.widyip` (`AppGroup.identifier` in `Shared/SignDraft.swift`) |
| Widget kind | `WidyipWidget` |

The app and widget share the equipped placard (UserDefaults suite) and image files (`PlacardImages/`) through the App Group.

## Build and run

`Widyip.xcodeproj` is generated from `project.yml` and is not checked in.

```sh
brew install xcodegen
xcodegen generate
open Widyip.xcodeproj
```

Run the **Widyip** scheme on an iPhone simulator or device. Signing uses automatic provisioning with the team in `project.yml`; both bundle IDs and the App Group must exist in the Apple Developer account.
