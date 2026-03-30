#!/bin/sh
# Uninstallation script for luci-app-podkop-subscribe

# Don't exit on errors - we want to clean up as much as possible
set +e

echo "=========================================="
echo "luci-app-podkop-subscribe Uninstallation"
echo "=========================================="
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

echo "Step 1: Removing plugin files..."

PLUGIN_REMOVED=0

# Remove CGI scripts
if [ -f /www/cgi-bin/podkop-subscribe ]; then
    rm -f /www/cgi-bin/podkop-subscribe
    echo "  ✓ Removed: /www/cgi-bin/podkop-subscribe"
    PLUGIN_REMOVED=1
fi

# Remove JavaScript files
if [ -f /www/luci-static/resources/view/podkop/subscribe.js ]; then
    rm -f /www/luci-static/resources/view/podkop/subscribe.js
    echo "  ✓ Removed: subscribe.js"
    PLUGIN_REMOVED=1
fi

if [ -f /www/luci-static/resources/view/podkop/subscribe-loader.js ]; then
    rm -f /www/luci-static/resources/view/podkop/subscribe-loader.js
    echo "  ✓ Removed: subscribe-loader.js"
    PLUGIN_REMOVED=1
fi

# Remove ACL file
if [ -f /usr/share/rpcd/acl.d/luci-app-podkop-subscribe.json ]; then
    rm -f /usr/share/rpcd/acl.d/luci-app-podkop-subscribe.json
    echo "  ✓ Removed: ACL configuration"
    PLUGIN_REMOVED=1
fi

# Stop and remove auto-update init script
if [ -f /etc/init.d/podkop-subscribe ]; then
    /etc/init.d/podkop-subscribe stop    2>/dev/null || true
    /etc/init.d/podkop-subscribe disable 2>/dev/null || true
    rm -f /etc/init.d/podkop-subscribe
    echo "  ✓ Removed: /etc/init.d/podkop-subscribe"
    PLUGIN_REMOVED=1
fi

# Remove auto-update shell script
if [ -f /usr/share/podkop/subscribe-auto-update ]; then
    rm -f /usr/share/podkop/subscribe-auto-update
    rmdir /usr/share/podkop 2>/dev/null || true
    echo "  ✓ Removed: /usr/share/podkop/subscribe-auto-update"
    PLUGIN_REMOVED=1
fi

# Remove podkop-subscribe cron entries if any remain
if [ -f /etc/crontabs/root ]; then
    sed -i '/# podkop-subscribe-/d' /etc/crontabs/root 2>/dev/null
    kill -HUP "$(pidof crond)" 2>/dev/null || true
    echo "  ✓ Removed cron entries for podkop-subscribe"
fi

if [ "$PLUGIN_REMOVED" -eq 0 ]; then
    echo "  ℹ No plugin files found to remove (may already be removed)"
fi

# Remove subscribe URLs from podkop config
echo ""
echo "Step 2: Cleaning subscribe URLs from /etc/config/podkop..."

UCI_CLEANED=0

# Get all podkop sections and remove subscribe_url options
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/podkop ]; then
    # Remove current subscribe fields and legacy outbound subscribe fields from old versions
    for key in $(uci show podkop 2>/dev/null | grep -E "\.subscribe_url=|\.subscribe_url_outbound=|\.subscribe_interval=|\.subscribe_selected_index=" | cut -d'=' -f1); do
        # key = podkop.gg.subscribe_url
        if [ -n "$key" ]; then
            uci delete "$key" 2>/dev/null && {
                echo "  ✓ Removed: $key"
                UCI_CLEANED=1
            }
        fi
    done

    if [ "$UCI_CLEANED" -eq 1 ]; then
        uci commit podkop 2>/dev/null
        echo "  ✓ Changes committed to /etc/config/podkop"
    else
        echo "  ℹ No subscribe URLs found in config"
    fi
else
    echo "  ℹ UCI not available or podkop config not found"
fi

# Restore original section.js
echo ""
echo "Step 3: Restoring original Podkop section.js..."

RESTORED=0

section_js_has_plugin_code() {
    grep -q "view.podkop.subscribe\|enhanceSectionWithSubscribe" \
        /www/luci-static/resources/view/podkop/section.js 2>/dev/null
}

# Primary path: restore from the clean backup we created during install
if [ -f /www/luci-static/resources/view/podkop/section.js.backup ]; then
    cp /www/luci-static/resources/view/podkop/section.js.backup \
       /www/luci-static/resources/view/podkop/section.js
    rm -f /www/luci-static/resources/view/podkop/section.js.backup
    echo "  ✓ Restored: section.js from backup"
    RESTORED=1
fi

# Fallback: /rom filesystem (OpenWrt squashfs read-only layer)
if [ "$RESTORED" -eq 0 ] && [ -f /rom/www/luci-static/resources/view/podkop/section.js ]; then
    cp /rom/www/luci-static/resources/view/podkop/section.js \
       /www/luci-static/resources/view/podkop/section.js
    echo "  ✓ Restored: section.js from /rom"
    RESTORED=1
fi

# Final status
if [ "$RESTORED" -eq 0 ]; then
    if [ -f /www/luci-static/resources/view/podkop/section.js ]; then
        if section_js_has_plugin_code; then
            echo ""
            echo "  ⚠ CRITICAL: section.js still contains plugin code!"
            echo "  ⚠ Podkop LuCI interface may not work correctly."
            echo ""
            echo "  To manually fix, reinstall luci-app-podkop from:"
            echo "    https://github.com/itdoginfo/podkop"
        fi
    else
        echo "  ⚠ section.js not found"
    fi
fi

echo ""
echo "Step 4: Restarting uhttpd..."
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo ""
echo "=========================================="
if [ "$RESTORED" -eq 1 ]; then
    echo "Uninstallation completed successfully!"
else
    echo "Uninstallation completed with warnings!"
fi
echo "=========================================="
echo ""
echo "✓ Plugin files have been removed."
echo "✓ Subscribe URLs have been cleaned from config."
echo "✓ Podkop and its dependencies have NOT been removed."
echo ""
echo "Please clear your browser cache (Ctrl+F5) and reload LuCI."
echo ""
