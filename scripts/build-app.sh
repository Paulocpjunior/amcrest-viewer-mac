#!/usr/bin/env bash
# Gera "dist/Amcrest Viewer.app" a partir do pacote Swift.
# Uso: ./scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="dist/Amcrest Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AmcrestViewer" "$APP/Contents/MacOS/AmcrestViewer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Remove atributos estendidos (resource forks/Finder info que o iCloud/Documents
# adiciona) antes de assinar: senão o codesign recusa com "detritus not allowed".
xattr -cr "$APP"

# Assinatura local (ad hoc): basta para rodar neste Mac.
codesign --force --deep --sign - "$APP"

echo "Pronto: $APP"
echo "Para instalar: mv \"$APP\" /Applications/"
