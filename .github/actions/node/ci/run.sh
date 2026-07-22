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

validate_script_name() {
  local value="$1"
  local name="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9:_-]+$ ]]; then
    fail "$name contains unsupported characters."
  fi
}

validate_inputs() {
  [[ -d "$CLEARENT_APPLICATION_DIRECTORY" ]] ||
    fail "The application directory does not exist."
  [[ -f "$CLEARENT_APPLICATION_DIRECTORY/package.json" ]] ||
    fail "package.json was not found in the application directory."

  validate_relative_path "$CLEARENT_NODE_LOCK_FILE" "lock-file"
  validate_relative_path "$CLEARENT_COVERAGE_FILE" "coverage-file"
  validate_relative_path "$CLEARENT_TEST_RESULTS_PATH" "test-results-path"
  [[ -f "$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_NODE_LOCK_FILE" ]] ||
    fail "The configured npm lock file was not found."

  validate_script_name "$CLEARENT_NODE_BUILD_SCRIPT" "build-script"
  validate_script_name "$CLEARENT_NODE_LINT_SCRIPT" "lint-script"
  validate_script_name "$CLEARENT_NODE_TEST_SCRIPT" "test-script"
  canonical_bool "$CLEARENT_ENFORCE_LINT" "enforce-lint" >/dev/null
  canonical_bool "$CLEARENT_SKIP_TESTS" "skip-tests" >/dev/null
  canonical_bool "$CLEARENT_REQUIRE_COVERAGE" "require-coverage" >/dev/null
  canonical_bool "$CLEARENT_REQUIRE_PACKAGE_AUTH" "require-package-auth" >/dev/null

  [[ "$CLEARENT_NPM_AUTH_MODE" == "basic" || "$CLEARENT_NPM_AUTH_MODE" == "token" ]] ||
    fail "registry-auth-mode must be basic or token."
  [[ "$CLEARENT_NPM_REGISTRY_URL" =~ ^https://[^[:space:]]+/$ ]] ||
    fail "registry-url must be an HTTPS URL ending in '/'."
  if [[ "$(canonical_bool "$CLEARENT_REQUIRE_PACKAGE_AUTH" "require-package-auth")" == "true" && -z "${CLEARENT_PACKAGE_READ_TOKEN:-}" ]]; then
    fail "A package-read token is required for the configured npm registry."
  fi
}

require_package_script() {
  local script_name="$1"
  SCRIPT_NAME="$script_name" node -e '
    const scripts = require("./package.json").scripts || {};
    if (!Object.prototype.hasOwnProperty.call(scripts, process.env.SCRIPT_NAME)) {
      console.error("::error::package.json has no " + process.env.SCRIPT_NAME + " script.");
      process.exit(1);
    }
  '
}

run_ci() {
  validate_inputs
  cd "$CLEARENT_APPLICATION_DIRECTORY"

  npm ci --no-audit --fund=false

  if [[ "$(canonical_bool "$CLEARENT_ENFORCE_LINT" "enforce-lint")" == "true" ]]; then
    require_package_script "$CLEARENT_NODE_LINT_SCRIPT"
    npm run "$CLEARENT_NODE_LINT_SCRIPT"
  fi

  if [[ "$(canonical_bool "$CLEARENT_SKIP_TESTS" "skip-tests")" == "false" ]]; then
    require_package_script "$CLEARENT_NODE_TEST_SCRIPT"
    CI=true npm run "$CLEARENT_NODE_TEST_SCRIPT"
  fi

  require_package_script "$CLEARENT_NODE_BUILD_SCRIPT"
  npm run "$CLEARENT_NODE_BUILD_SCRIPT"

  local coverage_path="$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_COVERAGE_FILE"
  local results_path="$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_TEST_RESULTS_PATH"
  if [[ -f "$coverage_path" ]]; then
    printf 'coverage-file=%s\n' "$coverage_path" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  elif [[ "$(canonical_bool "$CLEARENT_SKIP_TESTS" "skip-tests")" == "false" && "$(canonical_bool "$CLEARENT_REQUIRE_COVERAGE" "require-coverage")" == "true" ]]; then
    fail "The required Node coverage report was not produced at $CLEARENT_COVERAGE_FILE."
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
