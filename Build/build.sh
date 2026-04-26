#!/bin/bash
# CP_Scripts Build System - Compiles Lua source to Lua 5.3 bytecode
# Usage: bash Build/build.sh [version]
# Example: bash Build/build.sh 1.2

set -e

LUAC="/c/Users/Cedric/Tools/lua53/luac53.exe"
BASE="/c/Users/Cedric/AppData/Roaming/REAPER/Scripts/CP_Scripts"
DIST="$BASE/dist"
VERSION="${1:-dev}"

echo "========================================"
echo "CP_Scripts Build System v1.1"
echo "Version: $VERSION"
echo "========================================"

# Clean previous build
rm -rf "$DIST"
mkdir -p "$DIST"

ERRORS=0

compile_file() {
    local src="$1"
    local dst="$2"
    local name=$(basename "$src")
    if "$LUAC" -s -o "$dst" "$src" 2>/dev/null; then
        echo "  [OK] $name"
    else
        echo "  [FAIL] $name"
        ERRORS=$((ERRORS + 1))
    fi
}

# Stamp version in a launcher file (replaces @version line)
stamp_version() {
    local file="$1"
    if [ -f "$file" ] && [ "$VERSION" != "dev" ]; then
        sed -i "s/^-- @version .*/-- @version $VERSION/" "$file"
    fi
}

# =============================================================
# FX Constellation
# =============================================================
echo ""
echo "--- FX Constellation ---"

FX_SRC="$BASE/FX Constellation/Modules"
FX_DIST="$DIST/FX Constellation"
FX_DATA53="$FX_DIST/Data53"

mkdir -p "$FX_DATA53"
mkdir -p "$FX_DIST/Data"

# Compile all modules
for f in "$FX_SRC"/*.lua; do
    name=$(basename "$f")
    compile_file "$f" "$FX_DATA53/$name"
done

# Copy distribution entry point + stamp version
cp "$BASE/Build/launchers/CP_FXConstellation.lua" "$FX_DIST/CP_FXConstellation.lua"
stamp_version "$FX_DIST/CP_FXConstellation.lua"
echo "  [COPY] CP_FXConstellation.lua (launcher)"

# Copy empty data directory structure (user data created at runtime)
echo "  [OK] Data/ structure"

# =============================================================
# Media Properties Toolbar
# =============================================================
echo ""
echo "--- Media Properties Toolbar ---"

MPT_SRC="$BASE/Media Properties Toolbar"
MPT_DIST="$DIST/Media Properties Toolbar"
MPT_DATA53="$MPT_DIST/Data53"

mkdir -p "$MPT_DATA53"

# Compile main scripts to bytecode
for script in \
    "CP_MediaPropertiesToolbar.lua" \
    "CP_MediaPropertiesToolbar_Settings.lua" \
    "CP_PitchShiftSelector.lua" \
    "CP_SourceManager.lua" \
    "CP_TakeRenamer.lua" \
    "CP_StretchMarkersControl.lua"; do
    if [ -f "$MPT_SRC/$script" ]; then
        compile_file "$MPT_SRC/$script" "$MPT_DATA53/$script"
    else
        echo "  [SKIP] $script (not found)"
    fi
done

# Copy launchers + stamp version
for launcher in "$BASE/Build/launchers/MPT"/*.lua; do
    if [ -f "$launcher" ]; then
        cp "$launcher" "$MPT_DIST/$(basename "$launcher")"
        stamp_version "$MPT_DIST/$(basename "$launcher")"
        echo "  [COPY] $(basename "$launcher") (launcher)"
    fi
done

# Copy small scripts as-is (ON/OFF toggles)
for small in "CP_MediaPropertiesToolbar_ON.lua" "CP_MediaPropertiesToolbar_OFF.lua"; do
    if [ -f "$MPT_SRC/$small" ]; then
        cp "$MPT_SRC/$small" "$MPT_DIST/$small"
        echo "  [COPY] $small (plaintext)"
    fi
done

# =============================================================
# Custom Toolbars
# =============================================================
echo ""
echo "--- Custom Toolbars ---"

CT_SRC="$BASE/Custom Toolbars/Modules"
CT_DIST="$DIST/Custom Toolbars"
CT_DATA53="$CT_DIST/Data53"

if [ -d "$CT_SRC" ] && [ "$(ls -A "$CT_SRC"/*.lua 2>/dev/null)" ]; then
    mkdir -p "$CT_DATA53"
    for f in "$CT_SRC"/*.lua; do
        name=$(basename "$f")
        compile_file "$f" "$CT_DATA53/$name"
    done
    # Copy launcher + stamp version
    cp "$BASE/Build/launchers/CP_CustomToolbars.lua" "$CT_DIST/CP_CustomToolbars.lua" 2>/dev/null || true
    stamp_version "$CT_DIST/CP_CustomToolbars.lua"
    echo "  [COPY] CP_CustomToolbars.lua (launcher)"
else
    echo "  [SKIP] Modules not found (refactor needed - see TASK-103)"
fi

# =============================================================
# Shared dependencies
# =============================================================
echo ""
echo "--- Shared Dependencies ---"

mkdir -p "$DIST/Various"
cp "$BASE/Various/CP_ImGuiStyleLoader.lua" "$DIST/Various/CP_ImGuiStyleLoader.lua"
echo "  [COPY] CP_ImGuiStyleLoader.lua (plaintext, shared)"
cp "$BASE/Various/CP_LicenseManager.lua" "$DIST/Various/CP_LicenseManager.lua"
echo "  [COPY] CP_LicenseManager.lua (plaintext, shared)"

# =============================================================
# Package
# =============================================================
echo ""
echo "--- Packaging ---"

# Add install instructions
cat > "$DIST/INSTALL.txt" << 'INSTALL_EOF'
CP Scripts - Paid Package
=========================

Installation:
1. Close REAPER
2. Copy all folders into your REAPER Scripts folder:
   [REAPER Resource Path]/Scripts/CP_Scripts/
3. Restart REAPER
4. Scripts appear in Actions > Show action list

FX Constellation License:
- Run the script, click the License button
- Enter your license key (received from Gumroad)

Requirements:
- REAPER 7.0+
- ReaImGui extension (install via ReaPack)
- SWS Extension
INSTALL_EOF
echo "  [CREATE] INSTALL.txt"

# Copy license
cp "$BASE/Build/LICENSE.txt" "$DIST/LICENSE.txt"
echo "  [COPY] LICENSE.txt"

# Create zip (use PowerShell on Windows if zip is not available)
echo ""
echo "--- Creating ZIP ---"
cd "$DIST"
if command -v zip &> /dev/null; then
    zip -r "$BASE/dist/CP_Scripts_Paid_v${VERSION}.zip" . -x "*.zip" > /dev/null 2>&1
    echo "  [ZIP] CP_Scripts_Paid_v${VERSION}.zip (zip)"
else
    # Fallback: use PowerShell Compress-Archive (Windows)
    WIN_DIST=$(cygpath -w "$DIST")
    WIN_ZIP=$(cygpath -w "$BASE/dist/CP_Scripts_Paid_v${VERSION}.zip")
    powershell.exe -NoProfile -Command "Compress-Archive -Path '$WIN_DIST/*' -DestinationPath '$WIN_ZIP' -Force" 2>/dev/null
    if [ -f "$BASE/dist/CP_Scripts_Paid_v${VERSION}.zip" ]; then
        echo "  [ZIP] CP_Scripts_Paid_v${VERSION}.zip (PowerShell)"
    else
        echo "  [WARN] ZIP creation failed - create manually from dist/ folder"
    fi
fi

# =============================================================
# Summary
# =============================================================
echo ""
echo "========================================"
if [ $ERRORS -eq 0 ]; then
    echo "BUILD SUCCESS"
else
    echo "BUILD COMPLETED WITH $ERRORS ERROR(S)"
fi
echo "Output: $DIST/"
if [ -f "$BASE/dist/CP_Scripts_Paid_v${VERSION}.zip" ]; then
    SIZE=$(du -h "$BASE/dist/CP_Scripts_Paid_v${VERSION}.zip" | cut -f1)
    echo "Package: CP_Scripts_Paid_v${VERSION}.zip ($SIZE)"
fi
echo "========================================"
