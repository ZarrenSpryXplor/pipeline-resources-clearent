#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

validate_relative_path() {
  local value="$1"
  local name="$2"
  if [[ -z "$value" || "$value" == /* || "/$value/" == *"/../"* ]]; then
    fail "$name must be a non-empty relative path without '..' segments."
  fi
}

validate_goals() {
  local value="$1"
  local -a parsed_goals
  read -r -a parsed_goals <<<"$value"
  [[ "${#parsed_goals[@]}" -gt 0 ]] ||
    fail "goals must contain at least one Maven goal."
  local goal
  for goal in "${parsed_goals[@]}"; do
    [[ "$goal" =~ ^[A-Za-z0-9:._-]+$ ]] ||
      fail "goals contains an unsupported Maven goal."
  done
}

validate_additional_arguments() {
  while IFS= read -r argument; do
    [[ -z "$argument" ]] && continue
    [[ "$argument" != *$'\r'* && "$argument" != *$'\n'* ]] ||
      fail "Each additional Maven argument must occupy one line."
  done <<<"$CLEARENT_MAVEN_ADDITIONAL_ARGUMENTS"
}

validate_inputs() {
  [[ -d "$CLEARENT_APPLICATION_DIRECTORY" ]] ||
    fail "The application directory does not exist."
  validate_relative_path "$CLEARENT_JAVA_POM_FILE" "pom-file"
  [[ -f "$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_JAVA_POM_FILE" ]] ||
    fail "The configured pom.xml was not found."
  validate_goals "$CLEARENT_MAVEN_PUBLISH_GOALS"
  validate_additional_arguments
}

publish_package() {
  validate_inputs
  [[ -n "${CLEARENT_MAVEN_SETTINGS:-}" && -f "$CLEARENT_MAVEN_SETTINGS" ]] ||
    fail "The temporary Maven settings file is unavailable."
  [[ -n "${CLEARENT_MAVEN_REPOSITORY_LOCAL:-}" ]] ||
    fail "The isolated Maven repository path is unavailable."

  local -a publish_goals additional_args
  read -r -a publish_goals <<<"$CLEARENT_MAVEN_PUBLISH_GOALS"
  while IFS= read -r argument; do
    [[ -z "$argument" ]] && continue
    additional_args+=("$argument")
  done <<<"$CLEARENT_MAVEN_ADDITIONAL_ARGUMENTS"

  cd "$CLEARENT_APPLICATION_DIRECTORY"
  mvn \
    --show-version \
    --batch-mode \
    --errors \
    --no-transfer-progress \
    --settings "$CLEARENT_MAVEN_SETTINGS" \
    "-Dmaven.repo.local=$CLEARENT_MAVEN_REPOSITORY_LOCAL" \
    -f "$CLEARENT_JAVA_POM_FILE" \
    "${additional_args[@]}" \
    "${publish_goals[@]}"
}

case "$mode" in
  validate) validate_inputs ;;
  publish) publish_package ;;
  *) fail "Expected validate or publish mode." ;;
esac
