#!/usr/bin/env bash
#
# Automated test suite for wp-safe-update-runner
# Exercises:
#   1. CLI help & flag parsing
#   2. Pre-flight check validations
#   3. Direct TypeScript smoke test runner (success & simulated failure)
#   4. Staged update dry-run
#   5. End-to-end mock update with backup generation and verification
#   6. Automated rollback on smoke test failure (verifying filesystem restoration)
#

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN_PATH="${REPO_ROOT}/bin/wp-safe-update"
SMOKE_TS="${REPO_ROOT}/src/smoke-test.ts"

TEST_WORK_DIR="${TMPDIR:-/tmp}/wp-safe-runner-tests-$$"
mkdir -p "$TEST_WORK_DIR"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    if [[ -d "$TEST_WORK_DIR" ]]; then
        find "$TEST_WORK_DIR" -mindepth 1 -delete 2>/dev/null || true
        rmdir "$TEST_WORK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  \033[0;32m✔ PASS:\033[0m $label"
        ((PASS_COUNT++))
    else
        echo -e "  \033[0;31m✖ FAIL:\033[0m $label (expected '$expected', got '$actual')"
        ((FAIL_COUNT++))
    fi
}

assert_file_exists() {
    local file_path="$1"
    local label="$2"
    if [[ -f "$file_path" ]]; then
        echo -e "  \033[0;32m✔ PASS:\033[0m $label"
        ((PASS_COUNT++))
    else
        echo -e "  \033[0;31m✖ FAIL:\033[0m $label (file not found: $file_path)"
        ((FAIL_COUNT++))
    fi
}

assert_file_contains() {
    local file_path="$1"
    local pattern="$2"
    local label="$3"
    if grep -q "$pattern" "$file_path" 2>/dev/null; then
        echo -e "  \033[0;32m✔ PASS:\033[0m $label"
        ((PASS_COUNT++))
    else
        echo -e "  \033[0;31m✖ FAIL:\033[0m $label (pattern '$pattern' not found in $file_path)"
        ((FAIL_COUNT++))
    fi
}

echo "=========================================================="
echo "Running wp-safe-update-runner Test Suite"
echo "Repository: ${REPO_ROOT}"
echo "Test Scratch: ${TEST_WORK_DIR}"
echo "=========================================================="

# ------------------------------------------------------------------------------
# Test 1: CLI Help output
# ------------------------------------------------------------------------------
echo -e "\n[Test 1] CLI help message displays usage information"
help_output=$("$BIN_PATH" --help)
if echo "$help_output" | grep -q "Usage: wp-safe-update"; then
    echo -e "  \033[0;32m✔ PASS:\033[0m Help text contains Usage banner"
    ((PASS_COUNT++))
else
    echo -e "  \033[0;31m✖ FAIL:\033[0m Help text missing Usage banner"
    ((FAIL_COUNT++))
fi

# ------------------------------------------------------------------------------
# Test 2: Pre-flight check failure on invalid path in live mode
# ------------------------------------------------------------------------------
echo -e "\n[Test 2] Pre-flight check exits with error when WP path is invalid without --mock"
set +e
"$BIN_PATH" --path="/nonexistent/directory/path/for/testing" >/dev/null 2>&1
exit_code=$?
set -e
assert_equal "1" "$exit_code" "Invalid WP path causes preflight exit code 1"

# ------------------------------------------------------------------------------
# Test 3: Direct TypeScript smoke test runner
# ------------------------------------------------------------------------------
echo -e "\n[Test 3] TypeScript smoke-test runner: mock pass and mock failure"
if command -v bun >/dev/null 2>&1; then
    set +e
    bun run "$SMOKE_TS" --mock >/dev/null 2>&1
    mock_pass_exit=$?
    bun run "$SMOKE_TS" --mock-fail >/dev/null 2>&1
    mock_fail_exit=$?
    set -e
    assert_equal "0" "$mock_pass_exit" "src/smoke-test.ts --mock exits 0 on healthy routes"
    assert_equal "1" "$mock_fail_exit" "src/smoke-test.ts --mock-fail exits 1 on fatal error"
else
    echo "  (bun not installed, skipping direct ts test)"
fi

# ------------------------------------------------------------------------------
# Test 4: Dry-run mode
# ------------------------------------------------------------------------------
echo -e "\n[Test 4] Staged update dry-run mode"
MOCK_WP_DRY="${TEST_WORK_DIR}/wp-dry"
mkdir -p "${MOCK_WP_DRY}/wp-content/plugins/woocommerce"
echo "8.0.0" > "${MOCK_WP_DRY}/wp-content/plugins/woocommerce/version.txt"

set +e
dry_output=$("$BIN_PATH" --path="$MOCK_WP_DRY" --mock --dry-run)
dry_exit=$?
set -e
assert_equal "0" "$dry_exit" "Dry run exits 0"
assert_file_contains "${MOCK_WP_DRY}/wp-content/plugins/woocommerce/version.txt" "8.0.0" "Dry run leaves plugin version unchanged"

# ------------------------------------------------------------------------------
# Test 5: End-to-end successful mock update with backup creation
# ------------------------------------------------------------------------------
echo -e "\n[Test 5] End-to-end successful update creates backups and updates plugins"
MOCK_WP_SUCCESS="${TEST_WORK_DIR}/wp-success"
MOCK_BACKUP_SUCCESS="${TEST_WORK_DIR}/backups-success"
mkdir -p "${MOCK_WP_SUCCESS}/wp-content/plugins/woocommerce"
echo "8.0.0" > "${MOCK_WP_SUCCESS}/wp-content/plugins/woocommerce/version.txt"
cat <<'PHP' > "${MOCK_WP_SUCCESS}/wp-content/plugins/woocommerce/woocommerce.php"
<?php
/**
 * Plugin Name: WooCommerce
 * Version: 8.0.0
 */
PHP

set +e
success_output=$("$BIN_PATH" --path="$MOCK_WP_SUCCESS" --backup-dir="$MOCK_BACKUP_SUCCESS" --mock)
success_exit=$?
set -e

assert_equal "0" "$success_exit" "Mock update completes with exit code 0"
assert_file_contains "${MOCK_WP_SUCCESS}/wp-content/plugins/woocommerce/version.txt" "8.1.0" "WooCommerce version successfully updated to 8.1.0"

# Verify backup files exist
backup_dirs=("$MOCK_BACKUP_SUCCESS"/backup_*)
latest_backup="${backup_dirs[0]}"
assert_file_exists "${latest_backup}/plugins.tar.gz" "Plugins archive (plugins.tar.gz) was created"
assert_file_exists "${latest_backup}/db.sql" "Database export (db.sql) was created"
assert_file_exists "${latest_backup}/pre-update-plugins.json" "Plugin metadata snapshot was created"

# ------------------------------------------------------------------------------
# Test 6: End-to-end failure triggers automated rollback
# ------------------------------------------------------------------------------
echo -e "\n[Test 6] Critical failure triggers automated rollback to pre-update state"
MOCK_WP_FAIL="${TEST_WORK_DIR}/wp-fail"
MOCK_BACKUP_FAIL="${TEST_WORK_DIR}/backups-fail"
mkdir -p "${MOCK_WP_FAIL}/wp-content/plugins/woocommerce"
echo "8.0.0" > "${MOCK_WP_FAIL}/wp-content/plugins/woocommerce/version.txt"
cat <<'PHP' > "${MOCK_WP_FAIL}/wp-content/plugins/woocommerce/woocommerce.php"
<?php
/**
 * Plugin Name: WooCommerce
 * Version: 8.0.0
 */
PHP

set +e
fail_output=$("$BIN_PATH" --path="$MOCK_WP_FAIL" --backup-dir="$MOCK_BACKUP_FAIL" --mock-fail 2>&1)
fail_exit=$?
set -e

assert_equal "1" "$fail_exit" "Runner returns exit code 1 when smoke test fails"

# Crucial check: verify that automated rollback restored the original version 8.0.0
assert_file_contains "${MOCK_WP_FAIL}/wp-content/plugins/woocommerce/version.txt" "8.0.0" "Automated rollback restored WooCommerce to 8.0.0"

# Verify rollback output reported rollback completion
if echo "$fail_output" | grep -q "ROLLBACK COMPLETED"; then
    echo -e "  \033[0;32m✔ PASS:\033[0m Runner reported successful automated rollback"
    ((PASS_COUNT++))
else
    echo -e "  \033[0;31m✖ FAIL:\033[0m Rollback completion message not detected in output"
    ((FAIL_COUNT++))
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo -e "\n=========================================================="
echo "Test Results: ${PASS_COUNT} Passed, ${FAIL_COUNT} Failed"
echo "=========================================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

exit 0
