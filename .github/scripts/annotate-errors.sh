#!/usr/bin/env bash
# Turns compiler, SwiftPM, and linker errors in a build log into GitHub
# annotations, so failures show inline on pull requests and through the
# checks API.
# Usage: annotate-errors.sh <build-log>
log="$1"
workspace="${GITHUB_WORKSPACE:-$PWD}/"

awk '
    /(^|: )error: / || /^ld: / || /Undefined symbols/ || /duplicate symbol/ ||
    /referenced from/ || /symbol\(s\) not found/ || /^[[:space:]]+"_/ {
        if (!seen[$0]++) print
    }
' "$log" | head -10 | while IFS= read -r line; do
    if [[ "$line" =~ ^(.+):([0-9]+):([0-9]+):\ error:\ (.*)$ ]]; then
        file="${BASH_REMATCH[1]#"$workspace"}"
        echo "::error file=${file},line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[4]}"
    else
        echo "::error::${line}"
    fi
done
