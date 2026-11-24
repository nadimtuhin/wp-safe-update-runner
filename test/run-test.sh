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

# shellcheck disable=SC2329 # invoked via trap
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
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  \033[0;31m✖ FAIL:\033[0m $label (expected '$expected', got '$actual')"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_file_exists() {
    local file_path="$1"
    local label="$2"
    if [[ -f "$file_path" ]]; then
        echo -e "  \033[0;32m✔ PASS:\033[0m $label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  \033[0;31m✖ FAIL:\033[0m $label (file not found: $file_path)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_file_contains() {
    local file_path="$1"
    local pattern="$2"
    local label="$3"
    if grep -q "$pattern" "$file_path" 2>/dev/null; then
        echo -e "  \033[0;32m✔ PASS:\033[0m $label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  \033[0;31m✖ FAIL:\033[0m $label (pattern '$pattern' not found in $file_path)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
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
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "  \033[0;31m✖ FAIL:\033[0m Help text missing Usage banner"
    FAIL_COUNT=$((FAIL_COUNT + 1))
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
"$BIN_PATH" --path="$MOCK_WP_DRY" --mock --dry-run >/dev/null
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
"$BIN_PATH" --path="$MOCK_WP_SUCCESS" --backup-dir="$MOCK_BACKUP_SUCCESS" --mock >/dev/null
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
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "  \033[0;31m✖ FAIL:\033[0m Rollback completion message not detected in output"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ------------------------------------------------------------------------------
# Live-mode tests using the WP-CLI stub in test/stubs/wp.
# bun is hidden from PATH so the built-in curl smoke test is exercised.
# ------------------------------------------------------------------------------
STUB_PATH="${REPO_ROOT}/test/stubs"
chmod +x "${STUB_PATH}/wp"
NO_BUN_PATH="$STUB_PATH"
IFS=':' read -ra _path_dirs <<< "$PATH"
for _d in "${_path_dirs[@]}"; do
    [[ -n "$_d" && ! -x "$_d/bun" ]] && NO_BUN_PATH="${NO_BUN_PATH}:${_d}"
done

make_live_site() {
    mkdir -p "$1/wp-content/plugins/woocommerce"
    echo "8.0.0" > "$1/wp-content/plugins/woocommerce/version.txt"
}

# Test 7: dry-run with a comma-separated plugin list passes separate args
echo -e "\n[Test 7] Dry-run splits comma-separated --plugins into separate WP-CLI args"
LIVE_DRY="${TEST_WORK_DIR}/live-dry"
make_live_site "$LIVE_DRY"
STUB_LOG="${TEST_WORK_DIR}/wp-dry.log"
: > "$STUB_LOG"
set +e
PATH="$NO_BUN_PATH" WP_STUB_LOG="$STUB_LOG" "$BIN_PATH" --path="$LIVE_DRY" \
    --url=http://127.0.0.1:1 --plugins=woocommerce,akismet --dry-run >/dev/null 2>&1
set -e
dry_cmd="$(grep '^plugin update' "$STUB_LOG" || true)"
assert_equal "plugin update --dry-run woocommerce akismet --path=$(cd "$LIVE_DRY" && pwd)" "$dry_cmd" \
    "Dry-run invokes 'wp plugin update --dry-run woocommerce akismet'"

# Test 8: unreachable site (curl HTTP 000) must fail the smoke test
echo -e "\n[Test 8] Built-in curl smoke test treats connection failure as FAIL"
LIVE_DOWN="${TEST_WORK_DIR}/live-down"
make_live_site "$LIVE_DOWN"
set +e
PATH="$NO_BUN_PATH" WP_STUB_LOG=/dev/null "$BIN_PATH" --path="$LIVE_DOWN" \
    --backup-dir="${TEST_WORK_DIR}/backups-down" --url=http://127.0.0.1:1 \
    --routes=/ --timeout=2 >/dev/null 2>&1
down_exit=$?
set -e
assert_equal "1" "$down_exit" "Unreachable site triggers rollback (exit 1)"

# Test 9: rollback must not wipe plugins when the archive is unreadable
echo -e "\n[Test 9] Rollback keeps current plugins when backup archive is corrupt"
LIVE_CORRUPT="${TEST_WORK_DIR}/live-corrupt"
CORRUPT_BACKUPS="${TEST_WORK_DIR}/backups-corrupt"
make_live_site "$LIVE_CORRUPT"
set +e
PATH="$NO_BUN_PATH" WP_STUB_LOG=/dev/null WP_STUB_UPDATE_MODE=corrupt-and-fail \
    WP_STUB_BACKUP_DIR="$CORRUPT_BACKUPS" "$BIN_PATH" --path="$LIVE_CORRUPT" \
    --backup-dir="$CORRUPT_BACKUPS" --url=http://127.0.0.1:1 >/dev/null 2>&1
set -e
assert_file_exists "${LIVE_CORRUPT}/wp-content/plugins/woocommerce/version.txt" \
    "Plugins directory left intact when archive fails verification"

# Test 10: backups (DB dump contains user hashes) are not world-readable
echo -e "\n[Test 10] Backup files are created owner-only"
# shellcheck disable=SC2012 # ls -ld mode string is portable (GNU + BSD); find -printf is not
perm_of() { ls -ld "$1" | cut -c1-10; }
assert_equal "-rw-------" "$(perm_of "${latest_backup}/db.sql")" "db.sql is mode 600"
assert_equal "drwx------" "$(perm_of "${latest_backup}")" "backup directory is mode 700"
assert_equal "-rw-r--r--" "$(perm_of "${MOCK_WP_FAIL}/wp-content/plugins/woocommerce/woocommerce.php")" \
    "Restored plugin files keep readable permissions"

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
