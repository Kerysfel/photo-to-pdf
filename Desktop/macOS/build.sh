#!/bin/bash
set -euo pipefail

if [[ $# != 1 || ( "$1" != "osx-arm64" && "$1" != "osx-x64" ) ]]; then
  echo "Usage: $0 osx-arm64|osx-x64" >&2
  exit 1
fi
rid=$1
root=$(cd "$(dirname "$0")/../.." && pwd)
dotnet=${DOTNET:-dotnet}
output="$root/Desktop/dist"
work=$(mktemp -d "${TMPDIR:-/tmp}/phototopdf-macos.XXXXXX")
trap 'rm -rf "$work"' EXIT
bundle="$work/Фото в PDF — приёмник.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$output" "$work/icon.iconset" "$work/image"

"$dotnet" publish "$root/Desktop/PhotoToPdf.Receiver/PhotoToPdf.Receiver.csproj" -c Release -r "$rid" --self-contained true -p:PublishSingleFile=false -o "$bundle/Contents/MacOS"
cp "$root/Desktop/macOS/Info.plist" "$bundle/Contents/Info.plist"
source_icon="$root/Assets/icon-source.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_icon" --out "$work/icon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$source_icon" --out "$work/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work/icon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - --timestamp=none "$bundle"
codesign --verify --deep --strict "$bundle"
cp -R "$bundle" "$work/image/"
ln -s /Applications "$work/image/Applications"
if [[ "$rid" == osx-arm64 ]]; then arch=Apple-Silicon; else arch=Intel; fi
dmg="$output/PhotoToPDF-Receiver-macOS-${arch}-0.1.0-preview.dmg"
hdiutil create -quiet -volname "Фото в PDF" -srcfolder "$work/image" -format UDZO -ov "$dmg"
echo "Created $dmg"
