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

validate_inputs() {
  [[ -d "$CLEARENT_APPLICATION_DIRECTORY" ]] ||
    fail "The application directory does not exist."
  validate_relative_path "$CLEARENT_PYTHON_REQUIREMENTS_FILE" "requirements-file"
  [[ -f "$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_PYTHON_REQUIREMENTS_FILE" ]] ||
    fail "The configured Python requirements file was not found."

  if [[ -n "$CLEARENT_PYTHON_TEST_REQUIREMENTS_FILE" ]]; then
    validate_relative_path "$CLEARENT_PYTHON_TEST_REQUIREMENTS_FILE" "test-requirements-file"
    [[ -f "$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_PYTHON_TEST_REQUIREMENTS_FILE" ]] ||
      fail "The configured Python test requirements file was not found."
  fi

  validate_relative_path "$CLEARENT_PYTHON_TEST_PATH" "test-path"
  validate_relative_path "$CLEARENT_PYTHON_COVERAGE_SOURCE" "coverage-source"
  validate_relative_path "$CLEARENT_COVERAGE_FILE" "coverage-file"
  validate_relative_path "$CLEARENT_TEST_RESULTS_PATH" "test-results-path"
  [[ "$CLEARENT_PYTHON_LINT_MODULE" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]] ||
    fail "lint-module contains unsupported characters."
  canonical_bool "$CLEARENT_ENFORCE_LINT" "enforce-lint" >/dev/null
  canonical_bool "$CLEARENT_SKIP_TESTS" "skip-tests" >/dev/null
  canonical_bool "$CLEARENT_REQUIRE_COVERAGE" "require-coverage" >/dev/null
}

run_ci() {
  validate_inputs
  cd "$CLEARENT_APPLICATION_DIRECTORY"

  python -m pip install --disable-pip-version-check -r "$CLEARENT_PYTHON_REQUIREMENTS_FILE"
  if [[ -n "$CLEARENT_PYTHON_TEST_REQUIREMENTS_FILE" ]]; then
    python -m pip install --disable-pip-version-check -r "$CLEARENT_PYTHON_TEST_REQUIREMENTS_FILE"
  fi

  if [[ "$(canonical_bool "$CLEARENT_ENFORCE_LINT" "enforce-lint")" == "true" ]]; then
    python -c "import $CLEARENT_PYTHON_LINT_MODULE" ||
      fail "The configured lint module is not installed by the application requirements."
    python -m "$CLEARENT_PYTHON_LINT_MODULE" check .
  fi

  local skip_tests
  skip_tests="$(canonical_bool "$CLEARENT_SKIP_TESTS" "skip-tests")"
  local coverage_path="$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_COVERAGE_FILE"
  local results_path="$CLEARENT_APPLICATION_DIRECTORY/$CLEARENT_TEST_RESULTS_PATH"
  if [[ "$skip_tests" == "false" ]]; then
    python -c 'import pytest, pytest_cov' ||
      fail "pytest and pytest-cov must be declared in the application test requirements."
    mkdir -p "$results_path" "$(dirname "$coverage_path")"
    python -m pytest "$CLEARENT_PYTHON_TEST_PATH" \
      --junitxml="$results_path/junit.xml" \
      --cov="$CLEARENT_PYTHON_COVERAGE_SOURCE" \
      --cov-report="term-missing" \
      --cov-report="xml:$coverage_path"
  fi

  python -m compileall -q \
    -x '(^|/)([.]git|[.]venv|venv|node_modules|[.]clearent-platform)(/|$)' \
    .

  if [[ -f "$coverage_path" ]]; then
    printf 'coverage-file=%s\n' "$coverage_path" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  elif [[ "$skip_tests" == "false" && "$(canonical_bool "$CLEARENT_REQUIRE_COVERAGE" "require-coverage")" == "true" ]]; then
    fail "The required Python coverage report was not produced at $CLEARENT_COVERAGE_FILE."
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
