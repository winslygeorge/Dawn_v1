#!/bin/bash

set -e

# === CONFIGURATION ===
PACKAGE="dawn"
VERSION="1.0-1"
ROCKSPEC_NAME="$PACKAGE-$VERSION.rockspec"
SO_MODULE_NAME="dawn.server.core"  # exposed as require('dawn.server.core')
C_SRC="server/check_version.cpp"
SO_FILENAME="core.so"

SRC_DIR=$(pwd)
BUILD_DIR="$SRC_DIR/build"
MODULE_ROOT="$BUILD_DIR/dawn"
ROCKSPEC_PATH="$BUILD_DIR/$ROCKSPEC_NAME"

echo "[1/6] Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$MODULE_ROOT"

echo "[2/6] Compiling .lua files to .luac..."
find "$SRC_DIR" -name "*.lua" | while read lua_file; do
  rel_path="${lua_file#$SRC_DIR/}"
  out_file="$MODULE_ROOT/${rel_path%.lua}.lua"
  mkdir -p "$(dirname "$out_file")"
  luac -o "$out_file" "$lua_file"
done

echo "[3/6] Copying .luac structure into 'dawn' root..."
# Already copied via output path, nothing extra to do

echo "[5/6] Generating .rockspec file: $ROCKSPEC_NAME"
echo "package = \"$PACKAGE\"" > "$ROCKSPEC_PATH"
echo "version = \"$VERSION\"" >> "$ROCKSPEC_PATH"
echo "source = {" >> "$ROCKSPEC_PATH"
echo "   url = \"git://example.com/your/repo.git\"" >> "$ROCKSPEC_PATH"
echo "}" >> "$ROCKSPEC_PATH"
echo "build = {" >> "$ROCKSPEC_PATH"
echo "   type = \"builtin\"," >> "$ROCKSPEC_PATH"
echo "   modules = {" >> "$ROCKSPEC_PATH"

# Add .luac modules
find "$MODULE_ROOT" -name "*.lua" | while read luac_file; do
  mod_path="${luac_file#$MODULE_ROOT/}"
  mod_name="${mod_path%.lua}"
  mod_name="${mod_name//\//.}"
  echo "      [\"$mod_name\"] = \"dawn/${mod_path}\"," >> "$ROCKSPEC_PATH"
done

echo "   }" >> "$ROCKSPEC_PATH"
echo "}" >> "$ROCKSPEC_PATH"

echo "[6/6] ✅ Done!"
echo "Build output: $BUILD_DIR"
echo "Rockspec:     $ROCKSPEC_PATH"
echo "You can now run:"
echo "    cd build && luarocks pack $ROCKSPEC_NAME"
