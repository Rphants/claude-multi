#!/bin/bash
# ============================================================================
# Claude Desktop Multi-Instance Manager (Hardened Fork)
# Based on: https://github.com/weidwonder/claude-desktop-multi-instance
# Security improvements & English-only UX by AgentRVM team
#
# Usage:
#   ./claude-multi.sh                    # Interactive menu
#   ./claude-multi.sh personal           # Create/launch "personal" instance
#   ./claude-multi.sh work               # Create/launch "work" instance
#   ./claude-multi.sh list               # List all instances
#   ./claude-multi.sh delete personal    # Delete an instance
#   ./claude-multi.sh wrapper personal   # Create .app for Dock/Spotlight
#   ./claude-multi.sh restore            # Restore original Claude config
#   ./claude-multi.sh diagnose           # Troubleshoot issues
#   ./claude-multi.sh fix                # Repair broken wrappers
# ============================================================================

set -euo pipefail

# ======================== CONFIG ========================
CLAUDE_INSTANCES_BASE="$HOME/.claude-instances"
ORIGINAL_CLAUDE_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_APP="/Applications/Claude.app"
VERSION="1.2.0-hardened"

# ======================== SECURITY HELPERS ========================

# Validate instance name: alphanumeric, hyphens, underscores only.
# Blocks path traversal, hidden files, and flag injection.
validate_instance_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "Error: Instance name cannot be empty."
        return 1
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        echo "Error: Instance name must start with a letter or number and contain only letters, numbers, hyphens, or underscores."
        echo "  Invalid: '$name'"
        return 1
    fi
    if [[ "$name" == "scripts" ]]; then
        echo "Error: 'scripts' is a reserved name."
        return 1
    fi
    if [[ ${#name} -gt 64 ]]; then
        echo "Error: Instance name must be 64 characters or fewer."
        return 1
    fi
    return 0
}

# Capitalize first letter (Bash 3.2 compatible)
capitalize() {
    local str="$1"
    local first
    first=$(echo "${str:0:1}" | tr '[:lower:]' '[:upper:]')
    echo "${first}${str:1}"
}

# Atomic symlink swap -- eliminates TOCTOU race condition.
# Uses ln -sfn which atomically replaces the symlink target.
safe_symlink() {
    local target="$1"
    local link_name="$2"

    # If it's a real directory (not a symlink), back it up first
    if [[ -d "$link_name" && ! -L "$link_name" ]]; then
        local timestamp
        timestamp=$(date +%s)
        mv "$link_name" "${link_name}.backup.${timestamp}"
        echo "  Backed up existing config -> $(basename "${link_name}.backup.${timestamp}")"
    fi

    # Atomic symlink replacement (ln -sfn replaces in one step)
    ln -sfn "$target" "$link_name"
}

# Set safe permissions on created files
set_safe_permissions() {
    local path="$1"
    local type="${2:-file}"

    case "$type" in
        dir)   chmod 700 "$path" ;;
        exec)  chmod 755 "$path" ;;
        file)  chmod 644 "$path" ;;
    esac
}

# Clean up old backups (keep the 5 most recent)
cleanup_old_backups() {
    local backup_pattern="$ORIGINAL_CLAUDE_DIR.backup.*"
    local count
    count=$(ls -1d $backup_pattern 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$count" -gt 5 ]]; then
        echo "  Cleaning up old backups (keeping 5 most recent)..."
        ls -1dt $backup_pattern 2>/dev/null | tail -n +6 | while read -r old_backup; do
            rm -rf "$old_backup"
            echo "    Removed: $(basename "$old_backup")"
        done
    fi
}

# ======================== CORE FUNCTIONS ========================

# Find the Claude executable inside Claude.app
find_claude_executable() {
    local exec_path=""
    for candidate in \
        "$CLAUDE_APP/Contents/MacOS/Claude" \
        "$CLAUDE_APP/Contents/MacOS/claude" \
        "$CLAUDE_APP/Contents/MacOS/Claude Desktop"; do
        if [[ -x "$candidate" ]]; then
            exec_path="$candidate"
            break
        fi
    done
    echo "$exec_path"
}

# Copy the Claude icon for app wrappers
copy_claude_icon() {
    local target_dir="$1"

    local icon_file
    icon_file=$(find "$CLAUDE_APP" -name "*.icns" -type f 2>/dev/null | head -n 1)

    if [[ -n "$icon_file" ]]; then
        cp "$icon_file" "$target_dir/claude-icon.icns"
        set_safe_permissions "$target_dir/claude-icon.icns" file
        echo "  Copied icon: $(basename "$icon_file")"
    else
        echo "  Warning: No Claude icon found. Wrapper will use default macOS icon."
    fi
}

# Restore original Claude config (undo all symlink changes)
restore_original_config() {
    echo ""
    echo "Restoring Claude to original configuration..."

    if [[ -L "$ORIGINAL_CLAUDE_DIR" ]]; then
        unlink "$ORIGINAL_CLAUDE_DIR"
        echo "  Removed instance symlink."
    fi

    local latest_backup
    latest_backup=$(ls -1dt "$ORIGINAL_CLAUDE_DIR.backup."* 2>/dev/null | head -n 1)

    if [[ -n "$latest_backup" ]]; then
        mv "$latest_backup" "$ORIGINAL_CLAUDE_DIR"
        echo "  Restored from: $(basename "$latest_backup")"
    else
        echo "  No backup found. Creating fresh config..."
        mkdir -p "$ORIGINAL_CLAUDE_DIR"
        set_safe_permissions "$ORIGINAL_CLAUDE_DIR" dir
        echo '{"mcpServers": {}}' > "$ORIGINAL_CLAUDE_DIR/claude_desktop_config.json"
    fi

    cleanup_old_backups
    echo "Done. Claude will use its default configuration on next launch."
}

# List all instances
list_instances() {
    echo ""
    echo "Claude Desktop Instances"
    echo "========================"

    if [[ ! -d "$CLAUDE_INSTANCES_BASE" ]]; then
        echo "  (none created yet)"
        echo ""
        echo "Create one with: $0 <instance-name>"
        return
    fi

    local count=0
    for dir in "$CLAUDE_INSTANCES_BASE"/*/; do
        [[ ! -d "$dir" ]] && continue
        local name
        name=$(basename "$dir")
        [[ "$name" == "scripts" ]] && continue

        local wrapper_status="no app wrapper"
        [[ -d "/Applications/Claude-${name}.app" ]] && wrapper_status="has app wrapper"

        local config_file="$dir/Application Support/Claude/claude_desktop_config.json"
        local config_status="not configured"
        [[ -f "$config_file" ]] && config_status="configured"

        echo "  $name  ($config_status, $wrapper_status)"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  (none created yet)"
    fi

    echo ""

    local wrapper_count=0
    for app in /Applications/Claude-*.app; do
        [[ ! -d "$app" ]] && continue
        if [[ $wrapper_count -eq 0 ]]; then
            echo "App Wrappers in /Applications:"
        fi
        local app_name
        app_name=$(basename "$app" .app)
        local inst_name="${app_name#Claude-}"
        local display_name="$app_name"
        if [[ -f "$app/Contents/Info.plist" ]]; then
            display_name=$(plutil -extract CFBundleDisplayName raw "$app/Contents/Info.plist" 2>/dev/null || echo "$app_name")
        fi
        echo "  $display_name -> instance '$inst_name'"
        wrapper_count=$((wrapper_count + 1))
    done

    if [[ $wrapper_count -eq 0 ]]; then
        echo "No app wrappers created yet."
        echo "  Create one with: $0 wrapper <instance-name>"
    fi
}

# Delete an instance
delete_instance() {
    local name="$1"

    if ! validate_instance_name "$name"; then
        return 1
    fi

    local instance_dir="$CLAUDE_INSTANCES_BASE/$name"
    if [[ ! -d "$instance_dir" ]]; then
        echo "Error: Instance '$name' does not exist."
        return 1
    fi

    echo ""
    echo "Deleting instance '$name'..."

    # If current symlink points to this instance, restore original
    if [[ -L "$ORIGINAL_CLAUDE_DIR" ]]; then
        local current_target
        current_target=$(readlink "$ORIGINAL_CLAUDE_DIR")
        if [[ "$current_target" == *"/$name/"* || "$current_target" == *"/$name" ]]; then
            restore_original_config
        fi
    fi

    rm -rf "$instance_dir"
    echo "  Deleted instance data."

    # Remove app wrapper if it exists
    local wrapper="/Applications/Claude-${name}.app"
    if [[ -d "$wrapper" ]]; then
        rm -rf "$wrapper"
        echo "  Deleted app wrapper."
    fi

    echo "Done."
}

# Create a .app wrapper for Dock/Spotlight
create_app_wrapper() {
    local name="$1"
    local display_name="${2:-Claude $(capitalize "$name")}"

    if ! validate_instance_name "$name"; then
        return 1
    fi

    local app_path="/Applications/Claude-${name}.app"
    local contents_dir="$app_path/Contents"
    local macos_dir="$contents_dir/MacOS"
    local resources_dir="$contents_dir/Resources"

    echo ""
    echo "Creating app wrapper: $display_name"

    # Clean existing wrapper
    if [[ -d "$app_path" ]]; then
        echo "  Removing existing wrapper..."
        rm -rf "$app_path"
    fi

    # Create bundle structure
    mkdir -p "$macos_dir" "$resources_dir"

    # Create launcher script
    local launcher="$macos_dir/launcher"
    cat > "$launcher" << 'LAUNCHER_EOF'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_NAME="__INSTANCE_NAME__"
CLAUDE_MULTI="$HOME/bin/claude-multi.sh"

if [[ -x "$CLAUDE_MULTI" ]]; then
    exec "$CLAUDE_MULTI" "$INSTANCE_NAME"
else
    osascript -e "display dialog \"claude-multi.sh not found at $CLAUDE_MULTI\" buttons {\"OK\"} default button \"OK\" with icon caution"
    exit 1
fi
LAUNCHER_EOF

    # Replace placeholder with actual instance name
    sed -i '' "s/__INSTANCE_NAME__/${name}/g" "$launcher"
    set_safe_permissions "$launcher" exec

    # Copy Claude icon
    copy_claude_icon "$resources_dir"

    # Determine icon filename
    local icon_name="claude-icon"
    if [[ -f "$resources_dir/claude-icon.icns" ]]; then
        icon_name="claude-icon"
    fi

    # Create Info.plist
    cat > "$contents_dir/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleName</key>
    <string>Claude-${name}</string>
    <key>CFBundleDisplayName</key>
    <string>${display_name}</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude-multi.${name}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>${icon_name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
</dict>
</plist>
PLIST_EOF

    set_safe_permissions "$contents_dir/Info.plist" file

    echo "  Created: $app_path"
    echo "  Display name: $display_name"
    echo ""
    echo "You can now find '$display_name' in Spotlight and drag it to your Dock."
}

# Launch (or create + launch) an instance
launch_instance() {
    local name="$1"

    if ! validate_instance_name "$name"; then
        return 1
    fi

    local instance_dir="$CLAUDE_INSTANCES_BASE/$name"
    local instance_config_dir="$instance_dir/Application Support/Claude"

    # Create instance directory if it doesn't exist
    if [[ ! -d "$instance_config_dir" ]]; then
        echo ""
        echo "Creating new instance: $name"
        mkdir -p "$instance_config_dir"
        set_safe_permissions "$instance_dir" dir
        set_safe_permissions "$instance_dir/Application Support" dir
        set_safe_permissions "$instance_config_dir" dir

        # Copy existing config if available
        if [[ -d "$ORIGINAL_CLAUDE_DIR" && ! -L "$ORIGINAL_CLAUDE_DIR" ]]; then
            if [[ -f "$ORIGINAL_CLAUDE_DIR/claude_desktop_config.json" ]]; then
                cp "$ORIGINAL_CLAUDE_DIR/claude_desktop_config.json" "$instance_config_dir/"
                echo "  Copied existing Claude config."
            fi
        fi

        # Create default config if none exists
        if [[ ! -f "$instance_config_dir/claude_desktop_config.json" ]]; then
            echo '{"mcpServers": {}}' > "$instance_config_dir/claude_desktop_config.json"
            echo "  Created fresh config."
        fi

        echo "  Instance directory: $instance_dir"
    fi

    # Switch the symlink to this instance
    echo ""
    echo "Switching to instance: $name"
    safe_symlink "$instance_config_dir" "$ORIGINAL_CLAUDE_DIR"
    echo "  Config symlinked: $ORIGINAL_CLAUDE_DIR -> $instance_config_dir"

    # Find and launch Claude
    local claude_exec
    claude_exec=$(find_claude_executable)

    if [[ -z "$claude_exec" ]]; then
        echo ""
        echo "Error: Could not find Claude executable in $CLAUDE_APP"
        echo "  Tried: Contents/MacOS/Claude, Contents/MacOS/claude, Contents/MacOS/Claude Desktop"
        echo ""
        echo "The config has been switched. You can launch Claude manually."
        return 1
    fi

    echo "  Launching Claude..."
    open -a "$CLAUDE_APP"
    echo ""
    echo "Done. Claude is now running with the '$name' instance."
}

# ======================== DIAGNOSTICS ========================

diagnose() {
    echo ""
    echo "Claude Multi-Instance Diagnostics"
    echo "================================="
    echo ""

    # Check Claude.app
    echo "Claude.app:"
    if [[ -d "$CLAUDE_APP" ]]; then
        echo "  Found at $CLAUDE_APP"
        local exec
        exec=$(find_claude_executable)
        if [[ -n "$exec" ]]; then
            echo "  Executable: $exec"
        else
            echo "  WARNING: No executable found!"
        fi
    else
        echo "  NOT FOUND at $CLAUDE_APP"
    fi
    echo ""

    # Check config directory
    echo "Config directory:"
    if [[ -L "$ORIGINAL_CLAUDE_DIR" ]]; then
        local target
        target=$(readlink "$ORIGINAL_CLAUDE_DIR")
        echo "  Symlinked to: $target"
        if [[ -d "$target" ]]; then
            echo "  Target exists: yes"
        else
            echo "  WARNING: Target does not exist!"
        fi
    elif [[ -d "$ORIGINAL_CLAUDE_DIR" ]]; then
        echo "  Original directory (no instance active)"
    else
        echo "  NOT FOUND"
    fi
    echo ""

    # Check instances
    echo "Instances:"
    if [[ -d "$CLAUDE_INSTANCES_BASE" ]]; then
        local count=0
        for dir in "$CLAUDE_INSTANCES_BASE"/*/; do
            [[ ! -d "$dir" ]] && continue
            local iname
            iname=$(basename "$dir")
            [[ "$iname" == "scripts" ]] && continue
            echo "  $iname: $dir"
            count=$((count + 1))
        done
        if [[ $count -eq 0 ]]; then
            echo "  (none)"
        fi
    else
        echo "  No instances directory yet."
    fi
    echo ""

    # Check backups
    echo "Backups:"
    local backup_count
    backup_count=$(ls -1d "$ORIGINAL_CLAUDE_DIR.backup."* 2>/dev/null | wc -l | tr -d ' ')
    echo "  $backup_count backup(s) found"
    echo ""

    # Check wrappers
    echo "App Wrappers:"
    local wcount=0
    for app in /Applications/Claude-*.app; do
        [[ ! -d "$app" ]] && continue
        echo "  $(basename "$app")"
        local lscript="$app/Contents/MacOS/launcher"
        if [[ -x "$lscript" ]]; then
            echo "    Launcher: OK"
        else
            echo "    WARNING: Launcher missing or not executable!"
        fi
        wcount=$((wcount + 1))
    done
    if [[ $wcount -eq 0 ]]; then
        echo "  (none)"
    fi
}

# Fix broken app wrappers
fix_wrappers() {
    echo ""
    echo "Checking app wrappers for issues..."
    local fixed=0

    for app in /Applications/Claude-*.app; do
        [[ ! -d "$app" ]] && continue
        local app_name
        app_name=$(basename "$app" .app)
        local inst="${app_name#Claude-}"

        echo "  Checking $app_name..."

        # Fix launcher permissions
        local launcher="$app/Contents/MacOS/launcher"
        if [[ -f "$launcher" && ! -x "$launcher" ]]; then
            chmod 755 "$launcher"
            echo "    Fixed launcher permissions."
            fixed=$((fixed + 1))
        fi

        # Check Info.plist
        if [[ ! -f "$app/Contents/Info.plist" ]]; then
            echo "    WARNING: Info.plist missing. Re-create wrapper with: $0 wrapper $inst"
            fixed=$((fixed + 1))
        fi
    done

    if [[ $fixed -eq 0 ]]; then
        echo "  No repairs needed."
    else
        echo "  Repaired $fixed issue(s)."
    fi
}

# ======================== INTERACTIVE MENU ========================

show_menu() {
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1) Launch default instance"
    echo "  2) Launch existing instance"
    echo "  3) Create new instance"
    echo "  4) Delete an instance"
    echo "  5) Create app wrapper (Dock/Spotlight icon)"
    echo "  6) Restore original Claude config"
    echo "  7) Diagnose problems"
    echo "  8) Repair app wrappers"
    echo "  9) List all instances"
    echo ""
    read -p "Choose (1-9): " choice

    case "$choice" in
        1) launch_instance "default" ;;
        2)
            list_instances
            echo ""
            read -p "Instance name: " name
            [[ -n "$name" ]] && launch_instance "$name"
            ;;
        3)
            read -p "New instance name (e.g. personal, work): " name
            [[ -n "$name" ]] && launch_instance "$name"
            ;;
        4)
            list_instances
            echo ""
            read -p "Instance to delete: " name
            [[ -n "$name" ]] && delete_instance "$name"
            ;;
        5)
            list_instances
            echo ""
            read -p "Instance to create wrapper for: " name
            if [[ -n "$name" ]]; then
                local default_display="Claude $(capitalize "$name")"
                read -p "Display name [$default_display]: " display
                display="${display:-$default_display}"
                create_app_wrapper "$name" "$display"
            fi
            ;;
        6) restore_original_config ;;
        7) diagnose ;;
        8) fix_wrappers ;;
        9) list_instances ;;
        *)
            echo "Invalid choice."
            exit 1
            ;;
    esac
}

# ======================== MAIN ========================

echo "========================================"
echo "  Claude Desktop Multi-Instance Manager"
echo "  v$VERSION"
echo "========================================"

# Check Claude Desktop is installed
if [[ ! -d "$CLAUDE_APP" ]]; then
    echo ""
    echo "Error: Claude Desktop not found at $CLAUDE_APP"
    echo "Download it from: https://claude.ai/download"
    exit 1
fi

# Route commands
case "${1:-}" in
    "")        show_menu ;;
    list)      list_instances ;;
    delete)
        if [[ -n "${2:-}" ]]; then
            delete_instance "$2"
        else
            list_instances
            echo ""
            read -p "Instance to delete: " name
            [[ -n "$name" ]] && delete_instance "$name"
        fi
        ;;
    wrapper)
        if [[ -n "${2:-}" ]]; then
            inst="${2}"
            if ! validate_instance_name "$inst"; then exit 1; fi
            default_display="Claude $(capitalize "$inst")"
            read -p "Display name [$default_display]: " display
            display="${display:-$default_display}"
            create_app_wrapper "$inst" "$display"
        else
            list_instances
            echo ""
            read -p "Instance to create wrapper for: " name
            if [[ -n "$name" ]]; then
                default_display="Claude $(capitalize "$name")"
                read -p "Display name [$default_display]: " display
                display="${display:-$default_display}"
                create_app_wrapper "$name" "$display"
            fi
        fi
        ;;
    restore|reset)  restore_original_config ;;
    diagnose|debug) diagnose ;;
    fix|repair)     fix_wrappers ;;
    --version|-v)   echo "$VERSION" ;;
    --help|-h)
        echo ""
        echo "Usage: $0 [command] [args]"
        echo ""
        echo "Commands:"
        echo "  <name>              Create/launch an instance (e.g. 'personal', 'work')"
        echo "  list                List all instances and app wrappers"
        echo "  delete <name>       Delete an instance and its app wrapper"
        echo "  wrapper <name>      Create a .app wrapper for Dock/Spotlight"
        echo "  restore             Restore Claude's original default config"
        echo "  diagnose            Troubleshoot issues"
        echo "  fix                 Repair broken app wrappers"
        echo "  --version           Show version"
        echo ""
        echo "Examples:"
        echo "  $0 personal         # Launch with personal account"
        echo "  $0 work             # Launch with work/org account"
        echo "  $0 wrapper personal # Create 'Claude Personal' in your Dock"
        echo ""
        ;;
    *)
        # Treat as instance name
        launch_instance "$1"
        ;;
esac
