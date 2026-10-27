#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_app="$project_dir/dist/SmartFan.app"
installed_app="/Applications/SmartFan.app"
agent_dir="$HOME/Library/LaunchAgents"
agent_file="$agent_dir/com.shuai.smartfan.login.plist"
login_target="gui/$(id -u)/com.shuai.smartfan.login"

# Copy the existing signed build without recompiling or changing its service trust.
test -d "$source_app"
/usr/bin/codesign --verify --deep --strict "$source_app"
/usr/bin/plutil -lint "$project_dir/Resources/com.shuai.smartfan.login.plist"
if /usr/bin/pgrep -x SmartFan >/dev/null; then
    printf '%s\n' '请先从菜单退出 SmartFan，再安装更新。' >&2
    exit 1
fi
if [ -e "$installed_app" ]; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")
    test "$bundle_id" = 'com.shuai.smartfan.menubar'
    backup_dir=$(mktemp -d "$project_dir/.build/installed-backup.XXXXXX")
    /usr/bin/ditto "$installed_app" "$backup_dir/SmartFan.app"
    printf '已保留旧版：%s\n' "$backup_dir/SmartFan.app"
fi
/usr/bin/ditto "$source_app" "$installed_app"
/usr/bin/codesign --verify --deep --strict "$installed_app"

mkdir -p "$agent_dir"
if /bin/launchctl print "$login_target" >/dev/null 2>&1; then
    /bin/launchctl bootout "$login_target"
fi
/usr/bin/install -m 644 "$project_dir/Resources/com.shuai.smartfan.login.plist" "$agent_file"
/bin/launchctl enable "$login_target"
# RunAtLoad also exercises the login launch path now. No KeepAlive: quitting stays quit.
/bin/launchctl bootstrap "gui/$(id -u)" "$agent_file"
printf '%s\n' '已安装到 /Applications/SmartFan.app，并启用登录后自动控速。'
