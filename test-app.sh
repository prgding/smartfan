#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$project_dir"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/SMC.swift Sources/Models.swift Sources/ControlPolicy.swift Sources/ControlLifecycle.swift Sources/IPC.swift Sources/ServiceSupport.swift Sources/Helper.swift Sources/PersistentService.swift \
    Tests/ControlTests.swift -o .build/control-tests
.build/control-tests
