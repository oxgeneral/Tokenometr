#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
xcrun swiftc -O -swift-version 5 Sources/Localization.swift Sources/Tokenizer.swift Sources/Timeline.swift Sources/LiveMeter.swift \
  Sources/WebSocketFramer.swift Sources/CodexSocket.swift Sources/CLIStream.swift Sources/StreamAccumulator.swift Sources/ThreadLocator.swift Sources/StatisticsStore.swift Tests/main.swift -lsqlite3 -o .build/TokenometrTests
./.build/TokenometrTests
