# wp-safe-update-runner

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Runtime](https://img.shields.io/badge/runtime-Bash%20%7C%20Bun%20%7C%20Node-black.svg)](#prerequisites)

> Automated, resilient WordPress & WooCommerce plugin update runner with pre-update backups, staged WP-CLI execution, HTTP smoke tests, and automated rollback.

---

## The Problem

WordPress and WooCommerce plugin updates often introduce breaking changes:
- Incompatible WooCommerce extensions break checkout or cart totals.
- Uncaught PHP fatal errors result in the dreaded `"There has been a critical error on this website"` page.
- Native WP automatic updates lack automated pre-update backups and self-healing rollbacks.

**`wp-safe-update-runner`** automates updates with a safety-first pipeline. If anything breaks during update or smoke testing, the entire site state (plugins and database) is automatically restored to its pre-update state within seconds.

---

## Architecture: 5-Phase Safety Pipeline

```
┌────────────────────────┐
│  Phase 1: Pre-Flight   │  Verifies WP-CLI, core integrity & database connection
└───────────┬────────────┘
            ▼
┌────────────────────────┐
│  Phase 2: Full Backup  │  Exports MySQL database + archives wp-content/plugins
└───────────┬────────────┘
            ▼
┌────────────────────────┐
│  Phase 3: Update Exec  │  Runs WP-CLI plugin update (--all or targeted plugins)
└───────────┬────────────┘
            ▼
┌────────────────────────┐
│  Phase 4: Smoke Test   │  Tests Home, Shop, Cart, Checkout, wp-login (HTTP 200 + no fatal errors)
└───────────┬────────────┘
            ├─────────────────────────────────────────┐
            │ [PASS]                                  │ [FAIL]
            ▼                                         ▼
┌────────────────────────┐                ┌────────────────────────┐
│  Phase 5: Success      │                │  Automated Rollback    │
│  Reports updated state │                │  Restores DB & plugins │
└────────────────────────┘                └────────────────────────┘
```

1. **Pre-flight Checks**: Verifies `wp` CLI binary, WordPress core installation, and database connectivity.
2. **Pre-update Backups**: Creates a timestamped snapshot of `wp-content/plugins` (`.tar.gz`), exports database (`db.sql`), and records plugin version metadata.
3. **Staged Update Execution**: Executes updates via WP-CLI with targeted plugin support or `--all`.
4. **HTTP Smoke Testing**: Curls critical routes (`/`, `/shop/`, `/cart/`, `/checkout/`, `/wp-login.php`), validating HTTP status codes and scanning HTML output for PHP fatal errors or `wp-die` messages.
5. **Automated Rollback**: If any route throws a fatal error or returns a 5xx status code, the runner automatically restores the database export and untars the pre-update plugin archive.

---

## Prerequisites

- **Bash** (v4.0+)
- **WP-CLI** (`wp` command in `PATH`)
- **tar** & **curl**
- *(Optional)* **Bun** or **Node.js** to run the standalone TypeScript smoke test runner (`src/smoke-test.ts`). If neither is present, `wp-safe-update` uses its built-in bash/curl fallback.

---

## Installation

Clone the repository and link the binary:

```bash
git clone https://github.com/nadimtuhin/wp-safe-update-runner.git
cd wp-safe-update-runner

# Make executable
chmod +x bin/wp-safe-update src/smoke-test.ts test/run-test.sh

# Optional: link to your PATH
ln -s "$(pwd)/bin/wp-safe-update" /usr/local/bin/wp-safe-update
```

---

## Usage

### 1. Update All Plugins Safely

```bash
wp-safe-update --path=/var/www/html
```

### 2. Update Specific Plugins

```bash
wp-safe-update --path=/var/www/html --plugins=woocommerce,woocommerce-gateway-stripe
```

### 3. Dry-Run (Preview Changes)

```bash
wp-safe-update --path=/var/www/html --dry-run
```

### 4. Custom Routes & Backup Directory

```bash
wp-safe-update \
  --path=/var/www/html \
  --url=https://myshop.com \
  --routes=/,/shop/,/cart/,/checkout/,/my-account/,/wp-login.php \
  --backup-dir=/var/backups/wp-safe \
  --timeout=15
```

---

## CLI Options

| Flag | Description | Default |
|---|---|---|
| `-p, --path=<path>` | Path to WordPress root directory | Current directory (`.`) |
| `--plugins=<list>` | Comma-separated plugin names or `--all` | `--all` |
| `-u, --url=<url>` | Base site URL for HTTP smoke tests | Auto-detected from `wp option get siteurl` |
| `-r, --routes=<list>` | Critical routes to smoke test | `/,/shop/,/cart/,/checkout/,/wp-login.php` |
| `-b, --backup-dir=<dir>` | Directory to store pre-update snapshots | `<path>/wp-content/uploads/wp-safe-backups` |
| `-t, --timeout=<sec>` | HTTP timeout per smoke test request | `10` |
| `--dry-run` | Simulate update without modifying files or DB | `false` |
| `--mock` | Run in standalone mock mode (no live WP required) | `false` |
| `--mock-fail` | Simulate smoke test failure to verify rollback | `false` |
| `--skip-backup` | Skip pre-update database and file backup | `false` |
| `--skip-smoke` | Skip post-update HTTP smoke tests | `false` |
| `-h, --help` | Display help and exit | — |

---

## Standalone TypeScript Smoke Test Runner

You can also run the smoke test runner independently against any WordPress site:

```bash
bun run src/smoke-test.ts --url https://myshop.com --routes /,/shop/,/cart/,/checkout/,/wp-login.php
```

Or with JSON output for monitoring pipelines:

```bash
bun run src/smoke-test.ts --url https://myshop.com --json
```

---

## Testing & CI Verification

The project includes a test suite (`test/run-test.sh`) that tests:
- Pre-flight validation failures.
- Staged dry-run execution.
- End-to-end update simulation with backup file generation.
- Smoke test fatal error detection.
- Automated rollback execution, verifying that original plugin files and database are restored.

Run the test suite:

```bash
bash test/run-test.sh
```

---

## Production Automation (Cron Example)

Run weekly off-peak updates safely via crontab:

```cron
# Run every Sunday at 03:00 AM
0 3 * * 0 /usr/local/bin/wp-safe-update --path=/var/www/html --backup-dir=/var/backups/wp-safe >> /var/log/wp-safe-update.log 2>&1
```

---

## License

MIT License. Copyright (c) 2026 Nadim Tuhin.
