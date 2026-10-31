# DSH-SOLO App

See [project README](../README.md) for installation and pairing, and
[configuration and releases](../docs/RELEASING.md) for shared build defaults and Android signing.

```sh
flutter pub get
flutter test
flutter build apk --release --dart-define-from-file=../.generated/flutter-defines.json
```

Run `npm run configure` at the repository root before building. Release builds require signing environment variables documented in the release guide.
