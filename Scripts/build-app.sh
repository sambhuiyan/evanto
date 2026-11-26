#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="${EVANTO_OUTPUT_DIR:-$PWD}"
mkdir -p "$output_dir"
signer="${EVANTO_SIGN_IDENTITY:-}"
if [[ -z "$signer" && -d Evanto.app ]]; then
    # Reuse the leaf certificate from the existing app. TCC recognizes updates
    # signed by the same identity, even when the executable changes.
    signer=$(codesign --display --verbose=4 Evanto.app 2>&1 | sed -n 's/^Authority=//p' | sed -n '1p')
fi
if [[ -z "$signer" ]]; then
    candidates=$(/usr/bin/security find-identity -v -p codesigning | awk '/"Apple Development: / {print $2}')
    case "$(printf '%s\n' "$candidates" | awk 'NF {n++} END {print n+0}')" in
        1) signer="$candidates" ;;
        0) signer="-" ;;
        *) echo "Choose an Apple Development identity with EVANTO_SIGN_IDENTITY for the first build. Future builds reuse it." >&2; exit 1 ;;
    esac
fi
if [[ "$signer" == "-" ]]; then
    echo "Using ad-hoc signing. macOS can require fresh capture permissions after a changed build." >&2
fi
sign_flags=(--timestamp=none)
if [[ "$signer" == "Developer ID Application:"* ]]; then
    sign_flags=(--options runtime --timestamp)
fi
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
codex_binary="${EVANTO_CODEX_BINARY:-}"
if [[ -z "$codex_binary" ]]; then
    case "$(uname -m)" in
        arm64) npm_arch=arm64; rust_arch=aarch64 ;;
        x86_64) npm_arch=x64; rust_arch=x86_64 ;;
    esac
    for prefix in /opt/homebrew /usr/local; do
        native="$prefix/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-$npm_arch/vendor/$rust_arch-apple-darwin/bin/codex"
        if [[ -x "$native" ]]; then codex_binary="$native"; break; fi
    done
fi
if [[ -z "$codex_binary" ]]; then codex_binary="$(command -v codex || true)"; fi
if [[ ! -x "$codex_binary" ]] || ! /usr/bin/file -Lb "$codex_binary" | /usr/bin/grep -q 'Mach-O'; then
    echo "Set EVANTO_CODEX_BINARY to the official native Codex executable for this Mac." >&2
    exit 1
fi
/usr/bin/codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"' "$codex_binary"
stage=$(mktemp -d "$PWD/.build/evanto-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Evanto.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Helpers" "$bundle/Resources/Fonts" "$bundle/Resources/Codex"
model_dir="$PWD/.build/bangla"
model_name=ggml-bengaliai-whisper-medium-q5_0.bin
model_sha=2c64c7f1e2c8f2417ed1fe5b78c7238933c00a2cdc2ef33e7087a95475256605
mkdir -p "$model_dir" "$bundle/Frameworks" "$bundle/Resources/Speech"
if [[ ! -f "$model_dir/$model_name" ]]; then
    curl --fail --location --retry 2 "https://huggingface.co/winshades/bengaliai-whisper-medium-ggml/resolve/11cf5cbd282e0e46a761093939952f74906ddce1/$model_name" -o "$stage/model.bin"
    echo "$model_sha  $stage/model.bin" | shasum -a 256 -c -
    mv "$stage/model.bin" "$model_dir/$model_name"
fi
echo "$model_sha  $model_dir/$model_name" | shasum -a 256 -c -
install -m 644 "$model_dir/$model_name" "$bundle/Resources/$model_name"
install -m 644 Packaging/Speech/{BengaliAI-LICENSE,NOTICE,whisper-LICENSE,whisper.cpp-LICENSE} "$bundle/Resources/Speech/"
ditto .build/artifacts/evanto/whisper/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$bundle/Frameworks/whisper.framework"
codesign --force --sign "$signer" "${sign_flags[@]}" "$bundle/Frameworks/whisper.framework"
install -m 755 "$binary_dir/Evanto" "$bundle/MacOS/Evanto"
install_name_tool -change @rpath/whisper.framework/Versions/Current/whisper @executable_path/../Frameworks/whisper.framework/Versions/Current/whisper "$bundle/MacOS/Evanto"
# Remove the linker debug map, including absolute paths on the build machine.
strip -S "$bundle/MacOS/Evanto"
install -m 755 "$codex_binary" "$bundle/Helpers/codex"
install -m 644 Packaging/Codex/{LICENSE,NOTICE} "$bundle/Resources/Codex/"
install -m 644 Packaging/Info.plist "$bundle/Info.plist"
install -m 644 LICENSE "$bundle/Resources/LICENSE"
install -m 644 Packaging/Fonts/{DMSans.ttf,DMSerifText.ttf,DMSans-OFL.txt,DMSerifText-OFL.txt} "$bundle/Resources/Fonts/"
install -m 644 Packaging/Evanto.icns "$bundle/Resources/Evanto.icns"
codesign --force --sign "$signer" "${sign_flags[@]}" --identifier studio.evanto.mac "$stage/Evanto.app"
codesign --verify --deep --strict "$stage/Evanto.app"
swift - "$stage/Evanto.app" "$output_dir/Evanto.app" <<'SWIFT'
import Foundation
let manager = FileManager.default
let staged = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
if manager.fileExists(atPath: destination.path) {
    _ = try manager.replaceItemAt(destination, withItemAt: staged)
} else {
    try manager.moveItem(at: staged, to: destination)
}
SWIFT
codesign --verify --strict "$output_dir/Evanto.app"
echo "Built $output_dir/Evanto.app"
