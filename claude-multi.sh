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
VERSION="1.1.0-hardened"

# ======================== SECURITY HELPERS ========================

# Validate instance name: alphanumeric, hyphens, underscores only.
# Blocks path traversal (../, /), hidden files (.), and flag injection (-rf).
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

# Atomic symlink swap — eliminates TOCTOU race condition.
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
    local type="${2:-file}"  # "file" or "dir" or "exec"

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

    # Try to find .icns files
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

    # Remove symlink if present
    if [[ -L "$ORIGINAL_CLAUDE_DIR" ]]; then
        unlink "$ORIGINAL_CLAUDE_DIR"
        echo "  Removed instance symlink."
    fi

    # Restore the most recent backup
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

    # Show app wrappers
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
    s/MacOS/Claude" \
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

    # Try to find .icns files
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

    # Remove symlink if present
    if [[ -L "$ORIGINAL_CLAUDE_DIR" ]]; then
        unlink "$ORIGINAL_CLAUDE_DIR"
        echo "  Removed instance symlink."
    fi

    # Restore the most recent backup
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

    # Show app wrappers
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

    if [[ ! -d "$CLAUDE_INSTANCES_BASE/$name" ]]; then
        echo "Error: Instance '$name' does not exist."
        return 1
    fi

    echo ""
    echo "This will permanently delete:"
    echo "  - Instance config: $CLAUDE_INSTANCES_BASE/$name"
    [[ -d "/Applications/Claude-${name}.app" ]] && echo "  - App wrapper: /Applications/Claude-${name}.app"
    echo ""
    read -p "Type 'yes' to confirm deletion of '$name': " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo "Cancelled."
        return 0
    fi

    rm -rf "$CLAUDE_INSTANCES_BASE/$name"
    echo "  Deleted instance directory."

    if [[ -d "/Applications/Claude-${name}.app" ]]; then
        rm -rf "/Applications/Claude-${name}.app"
        echo "  Deleted app wrapper."
    fi

    echo "Instance '$name' has been removed."
}

# Create an app wrapper (.app bundle for Dock/Spotlight)
create_app_wrapper() {
    local instance_name="$1"
    local display_name="${2:-Claude $(echo "$instance_name" | sed 's/./\U&/')}"
    local wrapper_path="/Applications/Claude-${instance_name}.app"

    if ! validate_instance_name "$instance_name"; then
        return 1
    fi

    if [[ ! -d "$CLAUDE_INSTANCES_BASE/$instance_name" ]]; then
        echo "Error: Instance '$instance_name' does not exist. Create it first with: $0 $instance_name"
        return 1
    fi

    if [[ -d "$wrapper_path" ]]; then
        echo "App wrapper already exists: $wrapper_path"
        read -p "Overwrite? (y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            echo "Cancelled."
            return 0
        fi
        rm -rf "$wrapper_path"
    fi

    echo "Creating app wrapper: $display_name"

    # Create bundle structure
    mkdir -p "$wrapper_path/Contents/MacOS"
    mkdir -p "$wrapper_path/Contents/Resources"
    set_safe_permissions "$wrapper_path" dir
    set_safe_permissions "$wrapper_path/Contents" dir
    set_safe_permissions "$wrapper_path/Contents/MacOS" dir
    set_safe_permissions "$wrapper_path/Contents/Resources" dir

    # Info.plist
    cat > "$wrapper_path/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>claude-launcher</string>
  <key>CFBundleIdentifier</key>
  <string>com.anthropic.claude.${instance_name}</string>
  <key>CFBundleName</key>
  <string>${display_name}</string>
  <key>CFBundleDisplayName</key>
  <string>${display_name}</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>CFBundleIconFile</key>
  <string>claude-icon</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
    set_safe_permissions "$wrapper_path/Contents/Info.plist" file

    # Launcher script (hardened)
    cat > "$wrapper_path/Contents/MacOS/claude-launcher" << 'LAUNCHER_EOF'
#!/bin/bash
set -euo pipefail

# Derive instance name from app bundle path
APP_PATH=$(dirname "$(dirname "$(dirname "$0")")")
APP_NAME=$(basename "$APP_PATH")
INSTANCE_NAME="${APP_NAME#Claude-}"
INSTANCE_NAME="${INSTANCE_NAME%.app}"

CLAUDE_INSTANCES_BASE="$HOME/.claude-instances"
INSTANCE_DIR="$CLAUDE_INSTANCES_BASE/$INSTANCE_NAME"
ORIGINAL_CLAUDE_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_APP="/Applications/Claude.app"

# Validate instance name (security: prevent path traversal)
if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    osascript -e "display dialog \"Invalid instance name: $INSTANCE_NAME\" buttons {\"OK\"} with icon stop"
    exit 1
fi

# Verify instance exists
if [[ ! -d "$INSTANCE_DIR" ]]; then
    osascript -e "display dialog \"Instance '$INSTANCE_NAME' not found.

Run claude-multi.sh to create it first.\" buttons {\"OK\"} with icon stop"
    exit 1
fi

# Verify Claude.app exists
if [[ ! -d "$CLAUDE_APP" ]]; then
    osascript -e "display dialog \"Claude Desktop not found in /Applications. Please install it from claude.ai/download\" buttons {\"OK\"} with icon stop"
    exit 1
fi

# Find Claude executable
CLAUDE_EXECUTABLE=""
for exec_path in \
    "$CLAUDE_APP/Contents/MacOS/Claude" \
    "$CLAUDE_APP/Contents/MacOS/claude" \
    "$CLAUDE_APP/Contents/MacOS/Claude Desktop"; do
    if [[ -x "$exec_path" ]]; then
        CLAUDE_EXECUTABLE="$exec_path"
        break
    fi
done

if [[ -z "$CLAUDE_EXECUTABLE" ]]; then
    osascript -e "display dialog \"Could not find Claude executable. Please reinstall Claude Desktop.\" buttons {\"OK\"} with icon stop"
    exit 1
fi

# Back up current config if it's a real directory (not already a symlink)
if [[ -d "$ORIGINAL_CLAUDE_DIR" && ! -L "$ORIGINAL_CLAUDE_DIR" ]]; then
    TIMESTAMP=$(date +%s)
    mv "$ORIGINAL_CLAUDE_DIR" "${ORIGINAL_CLAUDE_DIR}.backup.${TIMESTAMP}"
fi

# Atomic symlink swap (ln -sfn replaces atomically, no TOCTOU race)
ln -sfn "$INSTANCE_DIR/Application Support/Claude" "$ORIGINAL_CLAUDE_DIR"

# Launch Claude
exec "$CLAUDE_EXECUTABLE" "$@"
LAUNCHER_EOF
    set_safe_permissions "$wrapper_path/Contents/MacOS/claude-launcher" exec

    # Copy icon
    copy_claude_icon "$wrapper_path/Contents/Resources"

    echo ""
    echo "App wrapper created: $wrapper_path"
    echo "  Name in Dock/Spotlight: $display_name"
    echo "  Instance data: $CLAUDE_INSTANCES_BASE/$instance_name"
    echo ""
    echo "You can now launch '$display_name' from Spotlight or drag it to your Dock."
}

# Launch (or create + launch) an instance
launch_instance() {
    local instance_name="$1"

    if ! validate_instance_name "$instance_name"; then
        return 1
    fi

    local instance_dir="$CLAUDE_INSTANCES_BASE/$instance_name"

    echo ""
    echo "Launching Claude Desktop instance: $instance_name"

    # Create instance directory if new
    mkdir -p "$instance_dir/Application Support/Claude"
    set_safe_permissions "$instance_dir" dir
    set_safe_permissions "$instance_dir/Application Support" dir
    set_safe_permissions "$instance_dir/Application Support/Claude" dir

    # Initialize config if missing
    if [[ ! -f "$instance_dir/Application Support/Claude/claude_desktop_config.json" ]]; then
        if [[ -f "$ORIGINAL_CLAUDE_DIR/claude_desktop_config.json" && ! -L "$ORIGINAL_CLAUDE_DIR" ]]; then
            cp "$ORIGINAL_CLAUDE_DIR/claude_desktop_config.json" "$instance_dir/Application Support/Claude/"
            echo "  Copied existing MCP config to new instance."
        else
            echo '{"mcpServers": {}}' > "$instance_dir/Application Support/Claude/claude_desktop_config.json"
            echo "  Created fresh config."
        fi
    fi

    # Atomic symlink swap
    safe_symlink "$instance_dir/Application Support/Claude" "$ORIGINAL_CLAUDE_DIR"
    echo "  Config switched to instance: $instance_name"

    # Clean up old backups
    cleanup_old_backups

    # Launch Claude
    echo "  Starting Claude Desktop..."
    open -n "$CLAUDE_APP"

    echo ""
    echo "Claude Desktop is running with instance: $instance_name"
    echo "  Config: $instance_dir/Application Support/Claude/claude_desktop_config.json"
    echo ""

    # Offer to create wrapper if none exists
    if [[ ! -d "/Applications/Claude-${instance_name}.app" ]]; then
        repairs needed."
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
                local default_display="Claude ${name^}"
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

echo "======================================"
echo "  Claude Desktop Multi-Instance Manager"
echo "  v$VERSION"
echo "======================================"

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
            default_display="Claude ${inst^}"
            read -p "Display name [$default_display]: " display
            display="${display:-$default_display}"
            create_app_wrapper "$inst" "$display"
        else
            list_instances
            echo ""
            read -p "Instance to create wrapper for: " name
            if [[ -n "$name" ]]; then
                default_display="Claude ${name^}"
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
