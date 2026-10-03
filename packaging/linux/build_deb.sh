#!/usr/bin/env bash
set -e

# LabScribe Linux .deb Packaging Automation
APP_NAME="labscribe"
VERSION="1.0.0"
ARCH="amd64"
DEB_DIR="build/linux_deb"
BUNDLE_DIR="build/linux/x64/release/bundle"

echo "=== Building Flutter Linux Release ==="
flutter build linux --release

echo "=== Preparing Debian Package Hierarchy ==="
rm -rf "$DEB_DIR"
mkdir -p "$DEB_DIR/DEBIAN"
mkdir -p "$DEB_DIR/usr/bin"
mkdir -p "$DEB_DIR/usr/lib/$APP_NAME"
mkdir -p "$DEB_DIR/usr/share/applications"
mkdir -p "$DEB_DIR/usr/share/icons/hicolor/256x256/apps"

# Generate DEBIAN/control file
cat <<EOF > "$DEB_DIR/DEBIAN/control"
Package: $APP_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: libgtk-3-0, libblkid1, liblzma5, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libsqlite3-0, ffmpeg, zenity
Maintainer: LabScribe Open Source Contributors <support@labscribe.dev>
Description: Local meeting and lecture companion with AI intelligence
 LabScribe records audio locally with minimal CPU overhead, transcribes
 multilingual discussions (English, Hindi, Hinglish), extracts tasks, and
 provides an interactive Q&A assistant.
EOF

# Copy binaries and bundle assets
echo "=== Copying Flutter Bundle Files ==="
cp -r "$BUNDLE_DIR/"* "$DEB_DIR/usr/lib/$APP_NAME/"
ln -sf "../lib/$APP_NAME/$APP_NAME" "$DEB_DIR/usr/bin/$APP_NAME"

# Copy Desktop integration files
cp packaging/linux/labscribe.desktop "$DEB_DIR/usr/share/applications/"
if [ -f assets/icon.png ]; then
  cp assets/icon.png "$DEB_DIR/usr/share/icons/hicolor/256x256/apps/$APP_NAME.png"
fi

# Set permissions
chmod 755 "$DEB_DIR/DEBIAN"
chmod 755 "$DEB_DIR/usr/lib/$APP_NAME/$APP_NAME"

echo "=== Building Debian Binary Package ==="
dpkg-deb --build --root-owner-group "$DEB_DIR" "${APP_NAME}_${VERSION}_${ARCH}.deb"

echo ">>> Successfully built ${APP_NAME}_${VERSION}_${ARCH}.deb <<<"
