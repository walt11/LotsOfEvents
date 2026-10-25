# Soft Gallery implementation

Implemented warm ivory paper, cream cards, serif screen headings, monospaced agenda labels, thin borders, and a rust accent. Dark mode uses slate-gray paper and cards, cream text, and a peach accent with dark text on filled buttons. Existing custom app accents remain unchanged.

Settings → Appearance offers System, Light, and Dark. Widgets follow device appearance and offer the new Soft Gallery preset alongside all prior presets. The default widget preset is now Charcoal, calibrated from the supplied side-by-side Weather widget screenshot. All prior presets, saved custom designs, and per-widget overrides remain available. The previous shared preset is retained in `themeBeforeCharcoal`. Users can continue editing gradients, colors, borders, accents, sources, and layouts.

The calendar remains compact, and event/reminder rows use individual paper cards. Existing EventKit behavior, continuous scrolling, speech input, navigation, and source preferences remain intact.

App icons are reproducible vector drawings exported as opaque 1024px PNGs, with light, dark, and tinted variants. Source: `scripts/GenerateGalleryIcon.swift`.

Validation: 45 unit tests passed; simulator light/dark screenshots inspected; signed device build passed. Installed successfully on the phone. Release archive 1.0 (1) uploaded successfully to App Store Connect through Xcode Organizer on October 25, 2026, after adding the shared-settings privacy manifest and required iPad orientation declarations. Apple processing and TestFlight availability are separate from upload completion.
