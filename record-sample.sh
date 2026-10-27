#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$project_dir/.build/module-cache"
if [ ! -x "$project_dir/.build/sensorlog" ] || [ "$project_dir/sensorlog.swift" -nt "$project_dir/.build/sensorlog" ]; then
    xcrun swiftc -swift-version 5 -O -module-cache-path "$project_dir/.build/module-cache" \
        "$project_dir/sensorlog.swift" -o "$project_dir/.build/sensorlog"
fi
exec "$project_dir/.build/sensorlog" "$@"
