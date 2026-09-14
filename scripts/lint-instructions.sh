#!/usr/bin/env bash
# Lints Resources/AppInstructions/*.md. Fails when a file is empty, larger than 4 KB, contains non-ASCII bytes,
# does not start with a "## " heading, or mentions a `wisp <verb>` that the CLI does not have. Warns (without
# failing) about `wisp chrome upload|mark|dialog|show|hide`, which land in the same release as the catalog.
# Usage: scripts/lint-instructions.sh [dir]
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="${1:-Resources/AppInstructions}"
MAX_BYTES=4096
ALLOWED="state click set type key scroll action select-text paste drag batch screenshot windows end apps launch chrome policy instructions move mouse-down mouse-up cancel status log doctor"

[ -d "$DIR" ] || { echo "lint-instructions: missing $DIR" >&2; exit 1; }

errors=0
warnings=0
files=0
fail() { echo "error: $1: $2" >&2; errors=$((errors + 1)); }
warn() { echo "warning: $1: $2" >&2; warnings=$((warnings + 1)); }

while IFS= read -r file; do
  files=$((files + 1))
  size=$(wc -c < "$file" | tr -d ' ')
  if [ "$size" -eq 0 ]; then fail "$file" "file is empty"; continue; fi
  if [ "$size" -gt "$MAX_BYTES" ]; then fail "$file" "file is $size bytes (limit $MAX_BYTES)"; fi
  # In the C locale [:print:] and [:space:] cover exactly the ASCII range; anything else is a non-ASCII or
  # control byte.
  if LC_ALL=C grep -qn '[^[:print:][:space:]]' "$file"; then
    fail "$file" "non-ASCII byte at line $(LC_ALL=C grep -n '[^[:print:][:space:]]' "$file" | head -1 | cut -d: -f1)"
  fi
  case "$(head -n 1 "$file")" in
    "## "?*) ;;
    *) fail "$file" "first line must be a '## Title' heading" ;;
  esac
  # Every `wisp <verb>` mention (lowercase, word-bounded) must name a real CLI verb.
  while IFS= read -r verb; do
    [ -n "$verb" ] || continue
    case " $ALLOWED " in
      *" $verb "*) ;;
      *) fail "$file" "unknown wisp verb '$verb'" ;;
    esac
  done < <(grep -oE '(^|[^[:alnum:]_])wisp [a-z][a-z-]*' "$file" | sed -E 's/^.*wisp //' | LC_ALL=C sort -u)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    warn "$file" "mentions a chrome subcommand landing in this release: $line"
  done < <(grep -nE 'wisp chrome (upload|mark|dialog|show|hide)' "$file" | cut -d: -f1 | sed 's/^/line /')
done < <(find "$DIR" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)

if [ "$files" -eq 0 ]; then echo "lint-instructions: no .md files in $DIR" >&2; exit 1; fi
echo "lint-instructions: $files files, $errors errors, $warnings warnings"
[ "$errors" -eq 0 ]
