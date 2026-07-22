#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

canonical_bool() {
  case "$1" in
    [Tt][Rr][Uu][Ee]) printf 'true' ;;
    [Ff][Aa][Ll][Ss][Ee]) printf 'false' ;;
    *) fail "$2 must be true or false." ;;
  esac
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
  local name="$2"
  local -a parsed_goals
  read -r -a parsed_goals <<<"$value"
  [[ "${#parsed_goals[@]}" -gt 0 ]] || fail "$name must contain at least one Maven goal."
  local goal
  for goal in "${parsed_goals[@]}"; do
    [[ "$goal" =~ ^[A-Za-z0-9:._-]+$ ]] ||
      fail "$name contains an unsupported Maven goal."
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
  validate_relative_path "$CLEARENT_COVERAGE_FILE" "coverage-file"
  validate_relative_path "$CLEARENT_TEST_RESULTS_PATH" "test-results-path"
  [[ -f "$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_JAVA_POM_FILE" ]] ||
    fail "The configured pom.xml was not found."

  validate_goals "$CLEARENT_MAVEN_LINT_GOALS" "lint-goals"
  validate_goals "$CLEARENT_MAVEN_TEST_GOALS" "test-goals"
  validate_goals "$CLEARENT_MAVEN_BUILD_GOALS" "build-goals"
  validate_additional_arguments
  canonical_bool "$CLEARENT_ENFORCE_LINT" "enforce-lint" >/dev/null
  canonical_bool "$CLEARENT_SKIP_TESTS" "skip-tests" >/dev/null
  canonical_bool "$CLEARENT_REQUIRE_COVERAGE" "require-coverage" >/dev/null
  canonical_bool "$CLEARENT_REQUIRE_PACKAGE_AUTH" "require-package-auth" >/dev/null
}

run_ci() {
  validate_inputs
  [[ -n "${CLEARENT_MAVEN_SETTINGS:-}" && -f "$CLEARENT_MAVEN_SETTINGS" ]] ||
    fail "The temporary Maven settings file is unavailable."
  [[ -n "${CLEARENT_MAVEN_REPOSITORY_LOCAL:-}" ]] ||
    fail "The isolated Maven repository path is unavailable."

  local -a common_args lint_goals test_goals build_goals additional_args
  common_args=(
    --show-version
    --batch-mode
    --errors
    --no-transfer-progress
    --settings "$CLEARENT_MAVEN_SETTINGS"
    "-Dmaven.repo.local=$CLEARENT_MAVEN_REPOSITORY_LOCAL"
    -f "$CLEARENT_JAVA_POM_FILE"
  )
  read -r -a lint_goals <<<"$CLEARENT_MAVEN_LINT_GOALS"
  read -r -a test_goals <<<"$CLEARENT_MAVEN_TEST_GOALS"
  read -r -a build_goals <<<"$CLEARENT_MAVEN_BUILD_GOALS"
  while IFS= read -r argument; do
    [[ -z "$argument" ]] && continue
    additional_args+=("$argument")
  done <<<"$CLEARENT_MAVEN_ADDITIONAL_ARGUMENTS"

  cd "$CLEARENT_APPLICATION_DIRECTORY"

  if [[ "$(canonical_bool "$CLEARENT_ENFORCE_LINT" "enforce-lint")" == "true" ]]; then
    mvn "${common_args[@]}" "${additional_args[@]}" "${lint_goals[@]}"
  fi

  local skip_tests
  skip_tests="$(canonical_bool "$CLEARENT_SKIP_TESTS" "skip-tests")"
  if [[ "$skip_tests" == "false" ]]; then
    mvn "${common_args[@]}" "${additional_args[@]}" "${test_goals[@]}"
  fi

  mvn "${common_args[@]}" "${additional_args[@]}" -DskipTests "${build_goals[@]}"

  local coverage_path="$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_COVERAGE_FILE"
  local results_path="$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_TEST_RESULTS_PATH"
  if [[ -f "$coverage_path" ]]; then
    printf 'coverage-file=%s\n' "$coverage_path" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  elif [[ "$skip_tests" == "false" && "$(canonical_bool "$CLEARENT_REQUIRE_COVERAGE" "require-coverage")" == "true" ]]; then
    fail "The required JaCoCo report was not produced at $CLEARENT_COVERAGE_FILE."
  else
    printf 'coverage-file=\n' >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  fi

  if [[ -e "$results_path" ]]; then
    printf 'test-results-path=%s\n' "$results_path" >>"$GITHUB_OUTPUT"
  else
    printf 'test-results-path=\n' >>"$GITHUB_OUTPUT"
  fi
}

case "$mode" in
  validate) validate_inputs ;;
  ci) run_ci ;;
  *) fail "Expected validate or ci mode." ;;
esac
