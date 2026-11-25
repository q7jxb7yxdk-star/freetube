#!/bin/bash
set -euo pipefail

# Build the runtime in Xcode's temporary directory. The sandbox grants writes
# to the declared bundle entries, so move completed directories into the app.
staging="$(mktemp -d "$TEMP_DIR/freetube-python.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
tar -xzf "$SCRIPT_INPUT_FILE_1" -C "$staging" Python.xcframework

xcframework="$staging/Python.xcframework"
bundle="$TARGET_BUILD_DIR/$WRAPPER_NAME"
home="$staging/python"
if [[ "$PLATFORM_NAME" == iphonesimulator ]]; then
    slice=ios-arm64_x86_64-simulator
else
    slice=ios-arm64
fi

read -r -a architectures <<< "$ARCHS"
architecture="${architectures[0]}"
mkdir -p "$home/lib" "$staging/Frameworks" "$bundle/Frameworks"
rsync -a --exclude='libpython*.dylib' "$xcframework/lib/" "$home/lib/"
rsync -a --exclude='libpython*.dylib' "$xcframework/$slice/lib-$architecture/" "$home/lib/"

# Copy other simulator architecture metadata and merge native extensions for a universal build.
shopt -s nullglob
for additional in "${architectures[@]:1}"; do
    overlay="$xcframework/$slice/lib-$additional"
    rsync -a --exclude='libpython*.dylib' --exclude='*.so' "$overlay/" "$home/lib/"
    for extension in "$overlay/python3.15/lib-dynload/"*.so; do
        merged="$home/lib/python3.15/lib-dynload/$(basename "$extension")"
        lipo -create "$merged" "$extension" -output "$merged"
    done
done

# CPython's iOS loader looks up native modules through .fwork markers.
# See https://docs.python.org/3.15/using/ios.html#adding-python-to-an-ios-project
for extension in "$home/lib/python3.15/lib-dynload/"*.so; do
    name="$(basename "$extension")"
    name="${name%%.*}"
    module="Frameworks/$name.framework"
    framework="$staging/$module"
    marker="${extension%.so}.fwork"

    mkdir "$framework"
    cp "$xcframework/build/iOS-dylib-Info-template.plist" "$framework/Info.plist"
    plutil -replace CFBundleExecutable -string "$name" "$framework/Info.plist"
    plutil -replace CFBundleIdentifier -string "$PRODUCT_BUNDLE_IDENTIFIER.${name//_/-}" "$framework/Info.plist"
    mv "$extension" "$framework/$name"
    printf '%s\n' "$module/$name" > "$marker"
    printf '%s\n' "${marker#"$staging/"}" > "$framework/$name.origin"

    privacy="$(dirname "$extension")/$name.xcprivacy"
    if [[ -f "$privacy" ]]; then
        mv "$privacy" "$framework/PrivacyInfo.xcprivacy"
    fi

    if [[ "$CODE_SIGNING_ALLOWED" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        read -r -a sign_flags <<< "${OTHER_CODE_SIGN_FLAGS:-}"
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${sign_flags[@]+"${sign_flags[@]}"} \
            --timestamp=none --generate-entitlement-der "$framework"
    fi
done

replace_bundle_entry() {
    local source="$1" destination="$2"
    if [[ -d "$destination" ]]; then
        mv "$destination" "$staging/previous/$(basename "$destination")"
    fi
    mv "$source" "$destination"
}

mkdir "$staging/previous"
replace_bundle_entry "$home" "$bundle/python"
for framework in "$staging/Frameworks/"*.framework; do
    replace_bundle_entry "$framework" "$bundle/Frameworks/$(basename "$framework")"
done
