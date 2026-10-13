# Launch Screen Assets

The centered launch mark reuses the existing Wingman app icon without changing
the app icon set. All three images have a logical size of 60 × 60 points:

| Launch asset | Existing source in `../AppIcon.appiconset/` |
| --- | --- |
| `LaunchImage.png` | `Icon-App-20x20@3x.png` (60 × 60 pixels) |
| `LaunchImage@2x.png` | `Icon-App-60x60@2x.png` (120 × 120 pixels) |
| `LaunchImage@3x.png` | `Icon-App-60x60@3x.png` (180 × 180 pixels) |

When updating the app icon, refresh these copies and keep the resource size in
`Runner/Base.lproj/LaunchScreen.storyboard` aligned with their logical size.
