# tools

## GenerateAppIcon.swift

Renders `FRIDAY/Assets.xcassets/AppIcon.appiconset/AppIcon.png` — the amber orb with voice
rings, in the app's own palette (`FridayTheme` ground `#0B0B0D`, amber `#FFB33B`).

```bash
swift tools/GenerateAppIcon.swift FRIDAY/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

Kept as code rather than a binary drop so the icon is reproducible and tweakable — arc
sweeps, weights and the core gradient are all constants at the top of the draw calls. Xcode
derives every smaller size from the single 1024×1024 source.
