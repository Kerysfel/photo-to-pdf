#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/phototopdf-ios-source.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/PhotoToPDF/PhotoToPDF.xcodeproj/xcshareddata/xcschemes" "$root/Desktop/dist"
cp -R "$root/PhotoToPDF" "$work/PhotoToPDF/PhotoToPDF"
cp "$root/PhotoToPDF.xcodeproj/project.pbxproj" "$work/PhotoToPDF/PhotoToPDF.xcodeproj/"
cp "$root/PhotoToPDF.xcodeproj/xcshareddata/xcschemes/PhotoToPDF.xcscheme" "$work/PhotoToPDF/PhotoToPDF.xcodeproj/xcshareddata/xcschemes/"
cp "$root/README.md" "$root/LICENSE" "$work/PhotoToPDF/"
output="$root/Desktop/dist/PhotoToPDF-iPhone-Xcode-source-1.5.zip"
rm -f "$output"
(cd "$work" && zip -qr "$output" PhotoToPDF -x '*/.DS_Store' '*/xcuserdata/*')
echo "Created $output"
