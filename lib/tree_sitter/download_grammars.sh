#!/usr/bin/env bash

# unused because wasm support is hard :(

set -e

ORG="tree-sitter"
DEST="grammars"
API="https://api.github.com/orgs/$ORG/repos?per_page=100"

mkdir -p "$DEST"
cd "$DEST"

echo "Fetching list of official Tree-sitter grammars..."

repos=$(curl -s "$API" | grep -oE '"name": ?"tree-sitter-[^"]+"' | cut -d'"' -f4)

for repo in $repos; do
  echo "Checking $repo for WASM release..."
  release_url="https://api.github.com/repos/$ORG/$repo/releases/latest"
  wasm_url=$(curl -s "$release_url" | grep browser_download_url | grep $repo.wasm | cut -d '"' -f4)
  if [ -n "$wasm_url" ]; then
    echo "Downloading $repo wasm..."
    curl -L -o "${repo}.wasm" "$wasm_url"
  else
    echo "No wasm release found for $repo."
  fi
done

ORG="tree-sitter-grammars"
DEST="grammars"
API="https://api.github.com/orgs/$ORG/repos?per_page=100"

mkdir -p "$DEST"
cd "$DEST"

echo "Fetching list of community Tree-sitter grammars..."

repos=$(curl -s "$API" | grep -oE '"name": ?"tree-sitter-[^"]+"' | cut -d'"' -f4)

for repo in $repos; do
  echo "Checking $repo for WASM release..."
  release_url="https://api.github.com/repos/$ORG/$repo/releases/latest"
  wasm_url=$(curl -s "$release_url" | grep browser_download_url | grep $repo.wasm | cut -d '"' -f4)
  if [ -n "$wasm_url" ]; then
    echo "Downloading $repo wasm..."
    curl -L -o "${repo}.wasm" "$wasm_url"
  else
    echo "No wasm release found for $repo."
  fi
done

echo "Done."