# build-hermes

Builds a NativeScript-friendly `hermes.xcframework` from `facebook/hermes` commit `eb461d8` with:

- static Hermes enabled
- Node-API support enabled

## Local use

```bash
./build_hermes_for_ios_next.sh
```

Useful overrides:

```bash
WORK_ROOT=/tmp/build-hermes \
OUTPUT_XCFRAMEWORK="$PWD/dist/hermes.xcframework" \
IOS_NEXT_DIR=/tmp/ios-next \
./build_hermes_for_ios_next.sh
```

The script forward-ports the latest public Node-API donor ref from `kraenhansen/hermes` onto upstream `eb461d8`, then builds:

- macOS framework
- iOS device framework
- iOS simulator framework

Finally it repackages the result as `hermes.xcframework` with NativeScript-friendly slice naming.

## CI

GitHub Actions builds the xcframework on macOS, uploads the zip as a workflow artifact, and publishes it into a draft GitHub release for each pushed commit on `main`.
