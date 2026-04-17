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
OUTPUT_HEADERS_DIR="$PWD/dist/hermes-headers" \
OUTPUT_TOOLS_DIR="$PWD/dist/hermes-tools-macos" \
IOS_NEXT_DIR=/tmp/ios-next \
./build_hermes_for_ios_next.sh
```

The script forward-ports the latest public Node-API donor ref from `kraenhansen/hermes` onto upstream `eb461d8`, then builds:

- macOS framework
- iOS device framework
- iOS simulator framework

Finally it repackages the result as `hermes.xcframework` with NativeScript-friendly slice naming.
The packaged xcframework also carries Hermes/JSI headers inside each framework slice, and the script emits sibling `hermes-headers` and `hermes-tools-macos` directories for release publishing.

## CI

GitHub Actions builds the xcframework on macOS, uploads the xcframework zip plus separate headers/tools archives as workflow artifacts, and publishes them into a draft GitHub release for each pushed commit on `main`.
