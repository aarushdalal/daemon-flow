# FLOW v0.4.0

**Panel UI overflow fix, dynamic card sizing, restored Omarchy surface chrome, and refreshed v0.4.0 showcase assets.**

### Highlights in v0.4.0:
- **Zero-Overflow Panel Layout**: Fixed `Panel.qml` horizontal and vertical overflow where long `lastError` notices or unwrapped rows expanded the layout beyond the card background. Dedicated a wrapped error notice row, constrained all stat/status/policy text elements (`Layout.minimumWidth: 0`, `elide: Text.ElideRight`), wrapped mode/hold controls with `Flow`, and switched popup height to `fittedContentHeight(mainLayout.implicitHeight)`.
- **Restored Surface Chrome & Motion**: Updated `MusicKeyboardPanel.qml` from legacy `Theme.*` references to `qs.Commons.Style` tokens (`Style.cornerRadius`, `Style.normalBorderColor`, `Style.duration(...)`, `Style.easeOut`) and enabled `clip: true` on the outer `BorderSurface` card.
- **Fallback Handler Fix**: Fixed `monitorProcess.onExited` in `Panel.qml` to update `_localStatusMessage` and `_localLastError` instead of readonly properties.
- **Updated Card-Only Assets**: Refreshed `assets/panel.png` (`875x650` RGBA card-only capture with transparent outer corners and no desktop background bleed) and `assets/showcase.svg`.
- **Testing**: All 34 unit & regression tests and native offscreen Quickshell service probe pass.

Read `README.md` before installation.
