#!/usr/bin/env bash
# Build the Zig JNI library, stage it into the Gradle project, and assemble the
# debug APK. Pass --install to push and launch it on the connected device.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="${ZIG:-zig}"

"$ZIG" build android

for abi in arm64-v8a x86_64; do
    dest="$here/android/app/src/main/jniLibs/$abi"
    mkdir -p "$dest"
    cp "$here/zig-out/android/$abi/libtimeato.so" "$dest/"
done

cd "$here/android"
./gradlew :app:assembleDebug

if [[ "${1:-}" == "--install" ]]; then
    ./gradlew :app:installDebug
    adb shell am start -n com.timeato.app/.MainActivity
fi
