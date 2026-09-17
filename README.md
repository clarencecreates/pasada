# Pasada

An offline-first iPhone app that turns a personal message into a jeepney-inspired Home Screen widget.

## What is built

- Cibby-inspired, content-first SwiftUI editor
- Original sign renderer with four paint palettes
- Two editable sign lines and quick-start phrases
- Native WidgetKit extension, ready for App Group storage in the production build
- Small and medium iPhone Home Screen widgets
- Widget refresh immediately after saving

## Open it in Xcode

This Mac currently has only Command Line Tools, so it cannot compile iOS apps yet. Install the full Xcode app from the Mac App Store, open Xcode once, then:

```sh
brew install xcodegen
cd /Users/clarencepardinas/projects/pasada
xcodegen generate
open Pasada.xcodeproj
```

In Xcode, select the **Pasada** target and set your Apple Developer Team.

Run the **Pasada** scheme on an iPhone simulator or device. In the app, create a sign, save it, then add the Pasada widget from the Home Screen widget gallery.

## Product direction

The implementation deliberately uses original SwiftUI lettering and colors instead of copied Pinterest imagery. The next high-value additions are a bespoke licensed typeface, a curated template pack, per-widget saved-sign selection, and a one-time Pro unlock for unlimited saved signs.
