#!/bin/bash
# Rebuilds the bundled Heimdall CLI from source and vendors it into the repo.
#
# OdinMac uses the proven, open-source Heimdall engine (libusb-based, no kext)
# to talk to Samsung devices in Download Mode. The prebuilt heimdall-suite cask
# is disabled on modern macOS (it needs an Intel-only kernel extension), so we
# build the CLI from source and link libusb statically — producing a single
# self-contained arm64 binary with no external dylib dependencies.
#
# Requirements: git, clang++, and libusb (brew install libusb)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/.build/Heimdall"
OUT_DIR="$REPO_ROOT/vendor/heimdall"
HEIMDALL_REPO="https://github.com/Benjamin-Dobell/Heimdall.git"
HEIMDALL_COMMIT="3997d5cc607e6c603c6e7c0d07e42e9868c62af2"
ODINMAC_PATCH="$REPO_ROOT/patches/heimdall-use-local-pit.patch"
MACOS_DETACH_PATCH="$REPO_ROOT/patches/heimdall-macos-kernel-detach.patch"
FLASH_BY_FILENAME_PATCH="$REPO_ROOT/patches/heimdall-flash-by-filename.patch"

LIBUSB_PREFIX="$(brew --prefix libusb 2>/dev/null || true)"
if [ -z "$LIBUSB_PREFIX" ] || [ ! -f "$LIBUSB_PREFIX/lib/libusb-1.0.a" ]; then
  echo "error: static libusb not found. Run: brew install libusb" >&2
  exit 1
fi

echo "==> Cloning Heimdall source..."
rm -rf "$SRC_DIR"
git clone --depth 1 "$HEIMDALL_REPO" "$SRC_DIR"
git -C "$SRC_DIR" fetch --depth 1 origin "$HEIMDALL_COMMIT"
git -C "$SRC_DIR" checkout --detach "$HEIMDALL_COMMIT"
git -C "$SRC_DIR" apply "$ODINMAC_PATCH"
git -C "$SRC_DIR" apply "$MACOS_DETACH_PATCH"
git -C "$SRC_DIR" apply "$FLASH_BY_FILENAME_PATCH"
COMMIT="$(cd "$SRC_DIR" && git rev-parse HEAD)"

echo "==> Compiling heimdall CLI (static libusb, arm64)..."
cd "$SRC_DIR"
clang++ -std=gnu++11 -O2 -w \
  -I heimdall/source -I libpit/source -I "$LIBUSB_PREFIX/include/libusb-1.0" \
  heimdall/source/*.cpp libpit/source/libpit.cpp \
  "$LIBUSB_PREFIX/lib/libusb-1.0.a" \
  -framework IOKit -framework CoreFoundation -framework Security -lobjc \
  -o heimdall_bin

echo "==> Vendoring into $OUT_DIR ..."
mkdir -p "$OUT_DIR"
cp heimdall_bin "$OUT_DIR/heimdall"
cp LICENSE "$OUT_DIR/LICENSE"
chmod +x "$OUT_DIR/heimdall"

cat > "$OUT_DIR/README.md" <<EOF
# Bundled Heimdall

This directory contains a prebuilt copy of the [Heimdall](https://github.com/Benjamin-Dobell/Heimdall)
command-line tool, which OdinMac uses as its flashing engine.

- **Version:** $("$OUT_DIR/heimdall" version 2>/dev/null | head -1)
- **Source commit:** \`$COMMIT\`
- **OdinMac patch:** Uses a firmware-supplied PIT for mapping without repartitioning or downloading the device PIT
- **Built for:** macOS arm64 (Apple Silicon), libusb linked statically
- **License:** MIT — see [LICENSE](LICENSE) (© Benjamin Dobell, Glass Echidna)

Rebuild with \`scripts/build-heimdall.sh\` (requires \`brew install libusb\`).
EOF

echo ""
echo "✓ Heimdall $("$OUT_DIR/heimdall" version | head -1) vendored at $OUT_DIR/heimdall"
otool -L "$OUT_DIR/heimdall"
