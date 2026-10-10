#!/usr/bin/env bun
/**
 * wp-safe-update-runner: HTTP smoke test runner
 * Validates critical WordPress & WooCommerce routes for HTTP 200 and absence of PHP fatal errors.
 */

declare const process: any;

interface RouteResult {
  route: string;
  url: string;
  status: number;
  ok: boolean;
  durationMs: number;
  error?: string;
}

const FATAL_PATTERNS = [
  /fatal error/i,
  /parse error/i,
  /there has been a critical error on this website/i,
  /wp-die-message/i,
  /call to undefined function/i,
  /uncaught error/i,
  /syntax error/i,
  /database error/i,
];

function parseArgs() {
  const args = process.argv.slice(2);
  const options: {
    baseUrl: string;
    routes: string[];
    timeoutMs: number;
    json: boolean;
    mock: boolean;
    mockFail: boolean;
  } = {
    baseUrl: "http://localhost:8080",
    routes: ["/", "/shop/", "/cart/", "/checkout/", "/wp-login.php"],
    timeoutMs: 10000,
    json: false,
    mock: false,
    mockFail: false,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--url" || arg === "-u") {
      options.baseUrl = args[++i] || options.baseUrl;
    } else if (arg.startsWith("--url=")) {
      options.baseUrl = arg.split("=")[1];
    } else if (arg === "--routes" || arg === "-r") {
      options.routes = (args[++i] || "")
        .split(",")
        .map((r) => r.trim())
        .filter(Boolean);
    } else if (arg.startsWith("--routes=")) {
      options.routes = arg
        .split("=")[1]
        .split(",")
        .map((r) => r.trim())
        .filter(Boolean);
    } else if (arg === "--timeout" || arg === "-t") {
      options.timeoutMs = parseInt(args[++i], 10) || options.timeoutMs;
    } else if (arg === "--json") {
      options.json = true;
    } else if (arg === "--mock") {
      options.mock = true;
    } else if (arg === "--mock-fail") {
      options.mock = true;
      options.mockFail = true;
    }
  }

  // Normalize baseUrl: remove trailing slash
  options.baseUrl = options.baseUrl.replace(/\/+$/, "");

  return options;
}

async function checkRoute(
  baseUrl: string,
  route: string,
  timeoutMs: number,
  mock: boolean,
  mockFail: boolean
): Promise<RouteResult> {
  const normalizedRoute = route.startsWith("/") ? route : `/${route}`;
  const targetUrl = `${baseUrl}${normalizedRoute}`;
  const start = Date.now();

  if (mock) {
    const durationMs = 15;
    if (mockFail && (route.includes("checkout") || route === "/checkout/")) {
      return {
        route,
        url: targetUrl,
        status: 500,
        ok: false,
        durationMs,
        error: "PHP Fatal error: Call to undefined function wc_get_checkout_url() in /var/www/wp-content/plugins/woocommerce/includes/class-wc-checkout.php:123",
      };
    }
    return {
      route,
      url: targetUrl,
      status: 200,
      ok: true,
      durationMs,
    };
  }

  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

    const res = await fetch(targetUrl, {
      method: "GET",
      signal: controller.signal,
      redirect: "follow",
      headers: {
        "User-Agent": "WPSafeUpdateRunner-SmokeTest/1.0",
        Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      },
    });

    clearTimeout(timeoutId);
    const durationMs = Date.now() - start;
    const bodyText = await res.text();

    // Check status code
    if (res.status >= 400 && res.status !== 401 && res.status !== 403) {
      // 401/403 might be expected on protected wp-login or behind basic auth, but 500/404 is bad
      return {
        route,
        url: targetUrl,
        status: res.status,
        ok: false,
        durationMs,
        error: `HTTP status ${res.status}`,
      };
    }

    // Inspect body for fatal error strings
    for (const pattern of FATAL_PATTERNS) {
      if (pattern.test(bodyText)) {
        const match = bodyText.match(pattern)?.[0];
        return {
          route,
          url: targetUrl,
          status: res.status,
          ok: false,
          durationMs,
          error: `Fatal error string detected: "${match}"`,
        };
      }
    }

    return {
      route,
      url: targetUrl,
      status: res.status,
      ok: true,
      durationMs,
    };
  } catch (err: any) {
    return {
      route,
      url: targetUrl,
      status: 0,
      ok: false,
      durationMs: Date.now() - start,
      error: err.name === "AbortError" ? `Request timed out after ${timeoutMs}ms` : err.message,
    };
  }
}

async function main() {
  const options = parseArgs();
  const results: RouteResult[] = [];
  let allPassed = true;

  if (!options.json) {
    console.log(`\x1b[36m[SMOKE TEST]\x1b[0m Target: ${options.baseUrl}`);
    console.log(`\x1b[36m[SMOKE TEST]\x1b[0m Testing ${options.routes.length} critical routes...`);
  }

  for (const route of options.routes) {
    const res = await checkRoute(
      options.baseUrl,
      route,
      options.timeoutMs,
      options.mock,
      options.mockFail
    );
    results.push(res);

    if (!res.ok) {
      allPassed = false;
      if (!options.json) {
        console.log(
          `  \x1b[31m✖ [FAIL]\x1b[0m ${res.route.padEnd(16)} (Status: ${res.status}, ${res.durationMs}ms) - ${res.error}`
        );
      }
    } else {
      if (!options.json) {
        console.log(
          `  \x1b[32m✔ [PASS]\x1b[0m ${res.route.padEnd(16)} (Status: ${res.status}, ${res.durationMs}ms)`
        );
      }
    }
  }

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          success: allPassed,
          baseUrl: options.baseUrl,
          testedAt: new Date().toISOString(),
          results,
        },
        null,
        2
      )
    );
  } else {
    if (allPassed) {
      console.log(`\x1b[32m[SMOKE TEST] All routes passed successfully.\x1b[0m\n`);
    } else {
      console.error(`\x1b[31m[SMOKE TEST] Critical failure detected on one or more routes.\x1b[0m\n`);
    }
  }

  process.exit(allPassed ? 0 : 1);
}

main().catch((err) => {
  console.error("Fatal smoke test runner error:", err);
  process.exit(1);
});
