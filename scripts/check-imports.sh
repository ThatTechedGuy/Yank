#!/bin/bash
# Enforces which module may import what. scripts/test.sh runs it first.
#   * ClipCore may import only Foundation, CryptoKit and os: never AppKit, SwiftUI or Vision,
#     so the core stays testable without macOS UI.
#   * GRDB may be imported only in ClipCore/Storage/, so all disk access goes through the Store.
#   * Neither the app (App/) nor ClipSystem may import GRDB.
# Exit code 1 when a rule is broken; each violation is printed as file:line: reason.
set -euo pipefail
cd "$(dirname "$0")/.."

core=Packages/ClipCore/Sources/ClipCore
failed=0

# Prints "file:line:module" for every Swift import in the given folders, including attributed
# ones (`@testable import X`) and kind-specific ones (`import struct Foo.Bar`).
imports() {
    grep -rnE '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]' --include='*.swift' "$@" |
        sed -E 's/^([^:]+:[0-9]+):.*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?([A-Za-z_]+).*/\1:\4/'
}

# Rules 1 and 2. `< <(...)` rather than a pipe, so the loop's changes to `failed` survive it.
while IFS=: read -r file line module; do
    case "$module" in
        Foundation | CryptoKit | os) ;; # Allowed: do nothing.
        GRDB) [[ "$file" == "$core/Storage/"* ]] || { echo "$file:$line: GRDB outside Storage/"; failed=1; } ;;
        *) echo "$file:$line: ClipCore must not import $module"; failed=1 ;;
    esac
done < <(imports "$core")

# Rule 3: the app and ClipSystem may import anything except GRDB.
while IFS=: read -r file line module; do
    [[ "$module" == GRDB ]] && { echo "$file:$line: only ClipCore/Storage/ may import GRDB"; failed=1; }
done < <(imports App Packages/ClipCore/Sources/ClipSystem)

[[ $failed == 0 ]] && echo "Import check passed."
exit $failed
