#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────────────────────
# check-imports.sh — enforces which module may import what. ≈ an ESLint `no-restricted-imports`
# rule, or Android lint checks for module boundaries.
#
# The rules (who may import what):
#   * ClipCore (Packages/ClipCore/Sources/ClipCore) may import only Foundation (Swift's standard
#     library extras: dates, strings, files), CryptoKit (hashing) and os (logging). Never AppKit,
#     SwiftUI or Vision. That keeps the core testable without macOS UI.
#   * GRDB (the database library) may be imported only in ClipCore/Storage/, so all disk access
#     goes through one place, the Store.
#   * Neither the app (App/) nor ClipSystem may import GRDB.
#
# Exit code 0 = all good, 1 = a rule is broken (each violation is printed as file:line: reason).
# scripts/test.sh runs this first on every test run.
# ─────────────────────────────────────────────────────────────────────────────────────────────

# Bash strict mode: -e stop on the first failing command, -u treat unset variables as errors,
# -o pipefail make a pipeline fail if any command in it fails (not just the last one).
set -euo pipefail
# Run from the repo root no matter where the script was called from.
# $0 is this script's path; dirname strips the file name. ≈ path.dirname(__filename) + "/..".
cd "$(dirname "$0")/.."

core=Packages/ClipCore/Sources/ClipCore
failed=0

# Prints one "file:line:module" line for every Swift `import` in the given folders, so the rules
# below can be checked with plain string compares. grep finds the import lines, including attributed
# ones such as `@testable import X` and kind-specific ones such as `import struct Foo.Bar` (missing
# those would let a forbidden import slip through); sed keeps just the file, line number and module.
imports() {
    grep -rnE '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]' --include='*.swift' "$@" |
        sed -E 's/^([^:]+:[0-9]+):.*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?([A-Za-z_]+).*/\1:\4/'
}

# Rules 1 and 2: look at every import inside ClipCore and flag the ones the rules forbid. Each
# line from `imports` is split on ":" into three variables (`while IFS=: read -r a b c`).
# `< <(command)` feeds the command's output into the loop (process substitution) instead of a
# pipe, so the loop runs in this shell and its changes to `failed` survive after it ends.
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
