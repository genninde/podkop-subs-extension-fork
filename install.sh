#!/bin/sh
# Installation script for luci-app-podkop-subscribe

set -e

REPO_URL="https://raw.githubusercontent.com/artemscine/luci-podkop-subscribe/main"
BASE_URL="${REPO_URL}/files"
OPENWRT_RELEASE=""
PKG_MANAGER=""

get_openwrt_release() {
    if [ -r /etc/openwrt_release ]; then
        OPENWRT_RELEASE=$(grep "^DISTRIB_RELEASE=" /etc/openwrt_release | cut -d"'" -f2)
    fi

    if [ -z "$OPENWRT_RELEASE" ] && [ -r /etc/os-release ]; then
        OPENWRT_RELEASE=$(grep "^OPENWRT_RELEASE=" /etc/os-release | cut -d'"' -f2)
    fi
}

detect_package_manager() {
    get_openwrt_release

    case "$OPENWRT_RELEASE" in
        25.12.*)
            PKG_MANAGER="apk"
            ;;
        *)
            PKG_MANAGER="opkg"
            ;;
    esac

    if [ "$PKG_MANAGER" = "apk" ] && ! command -v apk >/dev/null 2>&1; then
        if command -v opkg >/dev/null 2>&1; then
            PKG_MANAGER="opkg"
        fi
    fi

    if [ "$PKG_MANAGER" = "opkg" ] && ! command -v opkg >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            PKG_MANAGER="apk"
        fi
    fi

    if [ -z "$PKG_MANAGER" ] || ! command -v "$PKG_MANAGER" >/dev/null 2>&1; then
        echo "Error: No supported package manager found (opkg/apk)"
        exit 1
    fi
}

pkg_is_installed() {
    pkg_name="$1"

    if [ "$PKG_MANAGER" = "apk" ]; then
        apk info -e "$pkg_name" >/dev/null 2>&1
    else
        opkg list-installed | grep -qE "^${pkg_name} "
    fi
}

pkg_update() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk update >/dev/null 2>&1 || true
    else
        opkg update >/dev/null 2>&1 || true
    fi
}

pkg_install() {
    pkg_name="$1"

    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add "$pkg_name"
    else
        opkg install "$pkg_name"
    fi
}

echo "=========================================="
echo "luci-app-podkop-subscribe Installation"
echo "=========================================="
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

detect_package_manager
if [ -n "$OPENWRT_RELEASE" ]; then
    echo "Detected OpenWrt ${OPENWRT_RELEASE}, using ${PKG_MANAGER}"
else
    echo "OpenWrt version not detected, using ${PKG_MANAGER}"
fi
echo ""

# Check if Podkop is installed (check for either podkop or luci-app-podkop)
if ! pkg_is_installed podkop && ! pkg_is_installed luci-app-podkop; then
    echo "Error: Podkop is not installed"
    if [ "$PKG_MANAGER" = "apk" ]; then
        echo "Please install Podkop first: apk add podkop"
    else
        echo "Please install Podkop first: opkg install podkop"
    fi
    exit 1
fi

# Check if section.js exists or can be found
if [ ! -f /www/luci-static/resources/view/podkop/section.js ]; then
    echo "Warning: Podkop LuCI interface file (section.js) not found"
    echo "Please ensure Podkop LuCI interface is properly installed before running this plugin"
fi

# Check if wget is installed
if ! command -v wget >/dev/null 2>&1; then
    echo "Installing wget..."
    pkg_update
    pkg_install wget || {
        echo "Error: Failed to install wget"
        exit 1
    }
fi

echo "Step 1: Creating directories..."
mkdir -p /www/cgi-bin
mkdir -p /www/luci-static/resources/view/podkop
mkdir -p /usr/share/rpcd/acl.d

# ---------------------------------------------------------------------------
# Helper: check if section.js already has plugin code
# ---------------------------------------------------------------------------
section_js_has_plugin_code() {
    grep -q "view.podkop.subscribe\|enhanceSectionWithSubscribe" \
        /www/luci-static/resources/view/podkop/section.js 2>/dev/null
}

# ---------------------------------------------------------------------------
# patch_section_js: surgically add two lines to the original section.js
#   1. "require view.podkop.subscribe as subscribeExt";   (after main require)
#   2. if (subscribeExt...) block                          (before selector_proxy_links)
# ---------------------------------------------------------------------------
patch_section_js() {
    local file="/www/luci-static/resources/view/podkop/section.js"

    if section_js_has_plugin_code; then
        echo "  ℹ section.js already patched, skipping"
        return 0
    fi

    if [ ! -f "$file" ]; then
        echo "  ⚠ section.js not found, cannot patch"
        return 1
    fi

    local tmpfile="${file}.patching_$$"

    # Find insertion point for the enhance-block:
    # "selector_proxy_links" is always 3 lines after its "o = section.option(" opener:
    #   o = section.option(    <- insert BEFORE this line  (sel_line - 2)
    #     form.DynamicList,
    #     "selector_proxy_links",
    local sel_line
    sel_line=$(grep -n '"selector_proxy_links"' "$file" | head -1 | cut -d: -f1)
    if [ -z "$sel_line" ]; then
        echo "  ⚠ Cannot patch section.js: selector_proxy_links anchor not found"
        return 1
    fi
    local insert_before=$((sel_line - 2))
    [ "$insert_before" -lt 1 ] && insert_before=1

    local cur_line=0
    while IFS= read -r line || [ -n "$line" ]; do
        cur_line=$((cur_line + 1))

        # Patch 1: add require line immediately after the main require
        if printf '%s' "$line" | grep -q '"require view.podkop.main as main"'; then
            printf '%s\n' "$line" >> "$tmpfile"
            printf '"require view.podkop.subscribe as subscribeExt";\n' >> "$tmpfile"
            continue
        fi

        # Patch 2: insert enhance-block right before "o = section.option(" of selector
        if [ "$cur_line" -eq "$insert_before" ]; then
            printf '  if (subscribeExt && typeof subscribeExt.enhanceSectionWithSubscribe === "function") {\n' >> "$tmpfile"
            printf '    subscribeExt.enhanceSectionWithSubscribe(section);\n' >> "$tmpfile"
            printf '  }\n' >> "$tmpfile"
            printf '\n' >> "$tmpfile"
        fi

        printf '%s\n' "$line" >> "$tmpfile"
    done < "$file"

    mv "$tmpfile" "$file"
    echo "  ✓ section.js patched (require + enhanceSectionWithSubscribe injected)"
}

echo "Step 2: Backing up and patching original section.js..."

# Create backup of the original (clean, unpatched) section.js
if [ -f /www/luci-static/resources/view/podkop/section.js.backup ]; then
    if ! grep -q "view.podkop.subscribe\|enhanceSectionWithSubscribe" \
            /www/luci-static/resources/view/podkop/section.js.backup 2>/dev/null; then
        echo "  ✓ Clean backup already exists"
    else
        echo "  ⚠ Backup already contains plugin code — skipping backup overwrite"
    fi
elif [ -f /www/luci-static/resources/view/podkop/section.js ]; then
    if ! section_js_has_plugin_code; then
        cp /www/luci-static/resources/view/podkop/section.js \
           /www/luci-static/resources/view/podkop/section.js.backup
        echo "  ✓ Backup created: section.js.backup"
    else
        echo "  ℹ section.js already patched (reinstall?), backup skipped"
    fi
else
    echo "  ⚠ Warning: section.js not found"
fi

patch_section_js

echo "Step 3: Downloading and installing plugin files..."

# Download CGI scripts
echo "  - Installing podkop-subscribe..."
wget -q -O /www/cgi-bin/podkop-subscribe "${BASE_URL}/www/cgi-bin/podkop-subscribe" || {
    echo "Error: Failed to download podkop-subscribe"
    exit 1
}
chmod +x /www/cgi-bin/podkop-subscribe

echo "  - Installing subscribe.js..."
wget -q -O /www/luci-static/resources/view/podkop/subscribe.js "${BASE_URL}/www/luci-static/resources/view/podkop/subscribe.js" || {
    echo "Error: Failed to download subscribe.js"
    exit 1
}
chmod 644 /www/luci-static/resources/view/podkop/subscribe.js

echo "  - Installing subscribe-loader.js..."
wget -q -O /www/luci-static/resources/view/podkop/subscribe-loader.js "${BASE_URL}/www/luci-static/resources/view/podkop/subscribe-loader.js" || {
    echo "Warning: Failed to download subscribe-loader.js (optional file)"
}
chmod 644 /www/luci-static/resources/view/podkop/subscribe-loader.js 2>/dev/null || true

# Download ACL file
echo "  - Installing ACL configuration..."
wget -q -O /usr/share/rpcd/acl.d/luci-app-podkop-subscribe.json "${BASE_URL}/usr/share/rpcd/acl.d/luci-app-podkop-subscribe.json" || {
    echo "Error: Failed to download ACL file"
    exit 1
}

# Download auto-update script
echo "  - Installing subscribe-auto-update..."
mkdir -p /usr/share/podkop
wget -q -O /usr/share/podkop/subscribe-auto-update "${BASE_URL}/usr/share/podkop/subscribe-auto-update" || {
    echo "Warning: Failed to download subscribe-auto-update (auto-update feature will not work)"
}
chmod +x /usr/share/podkop/subscribe-auto-update 2>/dev/null || true

# Download init script for cron management
echo "  - Installing podkop-subscribe init script..."
wget -q -O /etc/init.d/podkop-subscribe "${BASE_URL}/etc/init.d/podkop-subscribe" || {
    echo "Warning: Failed to download podkop-subscribe init script (auto-update feature will not work)"
}
chmod +x /etc/init.d/podkop-subscribe 2>/dev/null || true
/etc/init.d/podkop-subscribe enable 2>/dev/null || true
/etc/init.d/podkop-subscribe start  2>/dev/null || true

echo "Step 4: Restarting uhttpd..."
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo ""
echo "=========================================="
echo "Installation completed successfully!"
echo "=========================================="
echo ""
echo "The plugin has been installed. Please:"
echo "1. Clear your browser cache (Ctrl+F5)"
echo "2. Navigate to: LuCI -> Services -> Podkop"
echo "3. Set Connection Type to 'Proxy'"
echo "4. Set Configuration Type to 'Connection URL', 'Selector' or 'URLTest'"
echo "5. You should see the Subscribe URL field"
echo ""
echo "Features:"
echo "  - Connection URL mode: Get configurations and apply to Podkop proxy"
echo "  - Selector mode: Fetch configurations and add selected entries to Selector"
echo "  - URLTest mode: Fetch configurations and add selected entries to URLTest"
echo "  - Auto-update: Set an interval (1h/6h/12h/24h/48h/72h) to refresh automatically"
echo "  - Supported protocols: vless://, ss://, trojan://, hy2://, hysteria2://"
echo "  - Theme support: Automatically adapts to light/dark themes"
echo ""
echo "To uninstall, run:"
echo "  sh <(wget -O - ${REPO_URL}/uninstall.sh)"
echo ""
