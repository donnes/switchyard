# App icon

`app-icon.icon` is the Icon Composer project. Its one layer, `fork.svg`, draws one track splitting into two in 120 px squares on a 1024 px canvas. The white fades along the diagonal of a 5 × 5 grid, from full on the top-left square to 20% at the bottom-right corner, the same range as Monodrive's folder. The fill is black. `logo.svg` is the same mark on a flat black square, for places that can't show the rendered icon.

Run `scripts/icons` after changing the project to export `switchyard-universal-1024.png`, the full-bleed square for the README, a website or the Omarchy app. `scripts/icons --check` exports it to a scratch folder and fails if the tracked copy differs. Exporting needs Icon Composer 2 or newer, from Xcode 26 or installed on its own; the script picks the newest one and pins design generation 26. Set `ICON_COMPOSER_TOOL` to `Icon Composer.app/Contents/Executables/ictool` to choose one.

Don't edit the PNG by hand.

## The macOS icon

The app needs no exported image. `apps/macos/scripts/build-app.sh` compiles `app-icon.icon` with `actool` into the bundle's `Assets.car`, which macOS 26 draws as Liquid Glass, and an `.icns`.
