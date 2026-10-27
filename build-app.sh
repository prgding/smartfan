#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$project_dir"
app="${SMARTFAN_BUILD_APP:-$project_dir/dist/SmartFan.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$project_dir/.build/module-cache"
common="Sources/SMC.swift Sources/Models.swift Sources/ControlPolicy.swift Sources/IPC.swift Sources/ServiceSupport.swift"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
    -module-cache-path "$project_dir/.build/module-cache" \
    $common Sources/Helper.swift Sources/PersistentService.swift Sources/HelperMain.swift -o "$app/Contents/MacOS/SmartFanHelper"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
    -module-cache-path "$project_dir/.build/module-cache" \
    $common Sources/ControlLifecycle.swift Sources/AppController.swift Sources/HardwareVerification.swift Sources/MenuApp.swift -o "$app/Contents/MacOS/SmartFan"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/bin/codesign --force --options runtime --sign - "$app/Contents/MacOS/SmartFanHelper"
/usr/bin/codesign --force --options runtime --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
printf '已构建：%s\n' "$app"
