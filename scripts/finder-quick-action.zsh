#!/bin/zsh
# Automator: Run Shell Script, shell /bin/zsh, pass input as arguments.
set -eu
archiver="$HOME/.local/bin/resolve-archive"
for folder in "$@"; do
    "$archiver" -- "$folder"
done
