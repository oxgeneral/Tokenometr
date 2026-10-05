#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -d dist/Tokenometr.app ]]; then ./scripts/build.sh; fi
open dist/Tokenometr.app
