# just_liquid_glass example

The platform folders (`android/`, `ios/`, etc.) aren't committed — regenerate
them once after cloning, then run as usual:

```sh
flutter create .
```

Two entrypoints:

- `lib/main.dart` — interactive demo: animated blobs over a scrollable
  backdrop, a pointer-following blob, and a glass/flat mode toggle.

  ```sh
  flutter run
  ```

- `lib/showcase_main.dart` — static grid of labeled cells for README
  screenshots: every shape (rect, rounded rect, pill, circle, arc), rotation,
  per-blob tints, shine on/off, and low/medium/high viscosity (blend radius).

  ```sh
  flutter run -t lib/showcase_main.dart
  ```

Glass mode needs an Impeller backend (iOS, Android, macOS); elsewhere it
falls back to flat.
