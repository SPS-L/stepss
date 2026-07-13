#!/bin/sh
# Update every submodule to the latest tip of its tracked branch.
set -e
cd "$(dirname "$0")"

git submodule update --remote --merge

echo
if git diff --quiet; then
    echo "All components already up to date."
else
    echo "Components moved:"
    git diff --submodule=log
    echo
    echo "Review the changes, then commit the new pointers:"
    echo "  git commit -am \"Update components to latest\" && git push"
fi
