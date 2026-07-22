#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

validate_inputs() {
  [[ -d "$CLEARENT_APPLICATION_DIRECTORY" ]] ||
    fail "The application directory does not exist."
  [[ -n "$CLEARENT_NODE_LOCK_FILE" && "$CLEARENT_NODE_LOCK_FILE" != /* && "/$CLEARENT_NODE_LOCK_FILE/" != *"/../"* ]] ||
    fail "lock-file must be a non-empty relative path without '..' segments."
  [[ -f "$CLEARENT_APPLICATION_DIRECTORY/package.json" ]] ||
    fail "package.json was not found."
  [[ -f "$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_NODE_LOCK_FILE" ]] ||
    fail "The configured npm lock file was not found."
  [[ "$CLEARENT_NPM_ACCESS" == "restricted" || "$CLEARENT_NPM_ACCESS" == "public" ]] ||
    fail "access must be restricted or public."
  [[ "$CLEARENT_NPM_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    fail "tag contains unsupported characters."
  [[ "$CLEARENT_NPM_REGISTRY_URL" =~ ^https://[^[:space:]]+/$ ]] ||
    fail "registry-url must be an HTTPS URL ending in '/'."
}

publish_package() {
  validate_inputs
  cd "$CLEARENT_APPLICATION_DIRECTORY"
  npm ci --no-audit --fund=false
  npm run build --if-present
  npm publish \
    --registry "$CLEARENT_NPM_REGISTRY_URL" \
    --access "$CLEARENT_NPM_ACCESS" \
    --tag "$CLEARENT_NPM_TAG"
}

case "$mode" in
  validate) validate_inputs ;;
  publish) publish_package ;;
  *) fail "Expected validate or publish mode." ;;
esac
