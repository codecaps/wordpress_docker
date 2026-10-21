# WordPress runtime images

This repository builds the PHP runtime every Code Capsules WordPress capsule runs on. The image is
a PHP runtime, not a WordPress release: WordPress core belongs to the capsule's volume (default
capsules mount `/var/www/html`; the upstream entrypoint copies core in only when the volume is
empty, and WordPress updates itself from then on) or to the capsule's repo (git capsules).

Nginx acts as a reverse proxy in front of PHP-FPM, both running in the same container, on top of
the official `wordpress:php<minor>-fpm` image.

---

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | The runtime. Requires `--build-arg BASE_IMAGE` and `--build-arg MIN_PHP_VERSION` (no defaults). |
| `tracks/php<minor>.env` | One track per PHP minor: `BASE_IMAGE` (digest-pinned), `MIN_PHP_VERSION`, `REVISION`. |
| `build.sh` / `push.sh` | Build / push one track. |
| `tests/smoke.sh` | Smoke test for a built image. |
| `git/` | Git capsule image: the runtime plus the capsule's repo (see `git/README.md`). |
| `docker_run.sh` | Run a locally built runtime against a MySQL on the host. |
| `legacy/` | Per-WordPress-version images for capsules not yet retrofitted. Delete once capsule-api's legacy image map is gone. |

## Tracks and tags

Tracks: `php8.3`, `php8.4` (default for new capsules), `php8.5`.

Images go to `europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime`:

- `php<minor>-r<REVISION>` (e.g. `php8.4-r1`): **immutable**. This is what capsule-api deploys
  (`WORDPRESS_RUNTIME_TAGS`). `push.sh` refuses to overwrite an existing one.
- `php<minor>`: a moving alias for humans. **Never deploy the moving tag**: pods pull
  `IfNotPresent`, so a re-pushed tag never reaches running capsules.

## Releasing a runtime

1. Bump the track: `BASE_IMAGE` digest
   (`docker buildx imagetools inspect wordpress:php8.4-fpm --format '{{json .Manifest.Digest}}'`)
   and `REVISION` in `tracks/php<minor>.env`. Raise `MIN_PHP_VERSION` when a security fix makes
   older PHP unacceptable.
2. Build: `./build.sh 8.4` (prints the immutable ref).
3. Smoke: `tests/smoke.sh <ref> <MIN_PHP_VERSION>` — every check must `PASS`.
4. Push: `./push.sh 8.4` (immutable tag, then the moving alias).
5. Bump the tag in capsule-api's `WORDPRESS_RUNTIME_TAGS` and deploy it.
6. Run capsule-api's `redeploy-wordpress-capsules` job to roll the new tag to every capsule on
   that track.

---

## Container Startup

`run.sh` is executed on container start. It:

1. Writes custom PHP ini values from `$WORDPRESS_CUSTOM_INI` to `$PHP_INI_DIR/conf.d/zz-custom.ini`
2. Writes custom PHP-FPM pool config from `$WORDPRESS_FPM_CONF` to `/usr/local/etc/php-fpm.d/zz-custom.conf`
3. Generates nginx config fragments from environment variables (rate limits, cache, security headers, etc.)
4. Validates nginx configuration with `nginx -t`
5. Starts nginx, nginx-prometheus-exporter, php-fpm_exporter, php-fpm and the internal wp-cron trigger as supervised background processes
6. Shuts everything down cleanly on SIGTERM (exit 0), and exits non-zero if nginx or php-fpm dies

`/healthz` is answered by PHP-FPM's ping path, so it fails when FPM is down.
Prometheus metrics are exposed on ports **9113** (nginx) and **9253** (PHP-FPM).

---

## Environment Variables

### Required WordPress Variables

| Variable | Description |
|---|---|
| `WORDPRESS_DB_HOST` | Database host (e.g., `host:3306`) |
| `WORDPRESS_DB_USER` | Database username |
| `WORDPRESS_DB_PASSWORD` | Database password |
| `WORDPRESS_DB_NAME` | Database name |

### WordPress Configuration

#### `WORDPRESS_CONFIG_EXTRA`

Arbitrary PHP injected directly into `wp-config.php` by the upstream WordPress Docker entrypoint. Use this for WordPress constants that belong in `wp-config.php`:

```
WORDPRESS_CONFIG_EXTRA=define('DISABLE_WP_CRON', true);
define('FORCE_SSL_ADMIN', true);
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');
```

> **Recommended:** Set `define('DISABLE_WP_CRON', true);` so WordPress doesn't waste a
> request self-triggering cron via its public URL (which `DISABLE_PUBLIC_WP_CRON` blocks
> anyway). Cron still runs: `run.sh` drives it internally (`WP_CRON_TRIGGER_ENABLED`,
> on by default), no platform-level CronJob or public wp-cron.php required.

#### `WORDPRESS_CUSTOM_INI`

Custom PHP ini settings merged with the defaults. Recommended for 2GB RAM / 1 CPU:

```ini
memory_limit = 128M
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 0
opcache.revalidate_freq = 0
opcache.enable_cli = 0
opcache.save_comments = 1
opcache.jit = tracing
opcache.jit_buffer_size = 64M
realpath_cache_ttl = 600
output_buffering = 4096
max_file_uploads = 10
max_execution_time = 60
max_input_time = 60
default_socket_timeout = 30
```

> **Note:** `upload_max_filesize` and `post_max_size` default to `MAX_UPLOAD_SIZE`. Override here only if you need them to differ from the nginx limit.

#### `WORDPRESS_FPM_CONF`

Custom PHP-FPM pool configuration merged with the defaults (`pm = dynamic`, `max_children = 12`,
`start_servers = 3`, `min/max_spare_servers = 3/6`, `max_requests = 500`). Recommended for 2GB RAM / 1 CPU:

```ini
[www]
pm = static
pm.max_children = 8
pm.max_requests = 500
request_terminate_timeout = 60s
```

**Scaling guide:**

| RAM | CPU | `pm.max_children` |
|---|---|---|
| 512MB | 0.5 | 3 |
| 1GB | 1 | 5 |
| 2GB | 1 | 8 |
| 4GB | 2 | 16 |

> **Security note:** `clear_env = no` is set so WordPress can read `WORDPRESS_DB_HOST` etc. via `getenv()`. This also means **all** environment variables in the container are visible to PHP code. Do not inject secrets as env vars that WordPress plugins should not access.

---

### Upload Size

#### `MAX_UPLOAD_SIZE`

Controls `client_max_body_size` in nginx **and** `upload_max_filesize` / `post_max_size` in PHP, keeping them in sync.

- Default: `64M`
- Accepts: `64M`, `128M`, `256M`, etc.

This is the single knob for upload size. Do not set `upload_max_filesize` in `WORDPRESS_CUSTOM_INI` to a value larger than this, or nginx will silently reject uploads with 413.

---

### Caching

#### `CACHE_TTL_SECONDS`

Enables FastCGI page caching and sets TTL in seconds. Must be a positive integer.

- Default: unset (caching disabled)
- Example: `CACHE_TTL_SECONDS=60` enables caching with 60s TTL
- Example: `CACHE_TTL_SECONDS=600` enables caching with 10-minute TTL

If this variable is not set, nginx runs with caching disabled (`fastcgi_cache_bypass 1` / `fastcgi_no_cache 1`).

> **Which strategy should I use?**
>
> - Start with `CACHE_TTL_SECONDS=60` for most content sites.
> - Use a higher value such as `CACHE_TTL_SECONDS=600` for mostly-static sites.
> - Leave `CACHE_TTL_SECONDS` unset for WooCommerce, membership/LMS, real-time dashboards, or when a WordPress cache plugin manages page caching.

#### `CACHE_IGNORE_QUERY_PARAMS`

Normalizes the FastCGI cache key by ignoring matching query parameter **names** (WordPress still receives the full query string). Requires `CACHE_TTL_SECONDS` to be set. If unset or `[]`, the cache key uses the full `$request_uri` (default).

- Format: JSON array of strings, e.g. `'["utm_*","fbclid"]'`
- Wildcards: `*` in a pattern matches any characters in the parameter name (e.g. `utm_*` matches `utm_term`, `utm_source`)
- Allowed characters per pattern: `A–Z`, `a–z`, `0–9`, `_`, `*`, `-`

Example with `CACHE_IGNORE_QUERY_PARAMS='["utm_*"]'`:

| Request | Cache behavior |
|---|---|
| `GET /page/1?utm_term=xyz` | MISS — rendered and stored |
| `GET /page/1?utm_term=abc` | HIT — same cache entry as above |
| `GET /page/1` | HIT — same cache entry |
| `GET /page/1?page=2&utm_term=xyz` | Key includes `page=2` only (utm params stripped from key) |

Non-ignored query parameters still differentiate cache entries. Parameter order in the URL is not normalized.

---

### Rate Limiting

| Variable | Default | Description |
|---|---|---|
| `RATE_LIMIT_NORMAL_ROUTES_RPM` | `120` | Req/min per IP for public routes |
| `RATE_LIMIT_PROTECTED_ROUTES_RPM` | `30` | Req/min per IP for wp-admin, wp-login |
| `RATE_LIMIT_API_ROUTES_RPM` | `60` | Req/min per IP for /wp-json/ |
| `RATE_LIMIT_MAX_CONN_PER_IP` | `30` | Max concurrent connections per IP |

All limits are **per client IP**. The client IP is resolved from `X-Forwarded-For`
(`real_ip_recursive on`), trusting private intermediary ranges plus Cloudflare's
edge ranges — see [Real Client IP & Cloudflare](#real-client-ip--cloudflare). If
the true client IP is not resolved correctly, every visitor shares one bucket and
trips these limits with spurious `429`s.

---

### Real Client IP & Cloudflare

nginx resolves the real client IP from `X-Forwarded-For` and uses it as the key for
all rate limits, the per-IP connection limit, access logs, and the IP passed to
WordPress (`REMOTE_ADDR` / `X-Real-IP`). `set_real_ip_from` in `nginx.conf` trusts:

- Private intermediary ranges (`10/8`, `172.16/12`, `192.168/16`) — Traefik / k8s LB / VPC.
- **Cloudflare's published edge ranges**, baked into the image at build time.

Cloudflare support is **automatic** — no env var. When the container is proxied by
Cloudflare, the edge IPs (which are public) appear in `X-Forwarded-For`. Trusting
them lets recursion walk past the edge to the real visitor. Without this, recursion
would stop at a Cloudflare IP and **collapse every visitor onto a handful of edge
IPs**, tripping the per-IP rate and connection limits. When Cloudflare is not in
front, trusting these ranges is harmless.

The ranges are fetched from `cloudflare.com/ips-v4` and `ips-v6` during `docker build`.
**Rebuild the image to refresh them.** If the fetch fails at build time, a
version-controlled snapshot (`cloudflare_ips.fallback.conf`) is used and a warning
is logged.

> ⚠️ **Security:** Trusting Cloudflare's *public* ranges means a client that can
> reach the origin **directly** (bypassing Cloudflare) could forge `X-Forwarded-For`
> to spoof or rotate client IPs — evading rate limits or framing another IP. Lock the
> origin to Cloudflare only: edge IP allowlist at your load balancer, Authenticated
> Origin Pulls, or a Cloudflare Tunnel.

---

### Security & Behaviour

| Variable | Default | Description |
|---|---|---|
| `XMLRPC_ENABLED` | `false` | Set to `true` to enable XML-RPC (Jetpack, WP mobile app, external publishing) |
| `DISABLE_PUBLIC_WP_CRON` | `true` | Restrict `wp-cron.php` to `127.0.0.1`. Triggered internally instead — see `WP_CRON_TRIGGER_ENABLED`. |
| `WP_CRON_TRIGGER_ENABLED` | `true` | `run.sh` runs a loop that calls `wp-cron.php` over `127.0.0.1` on an interval, since `DISABLE_PUBLIC_WP_CRON` blocks WordPress's own public-URL self-trigger. Set to `false` only if the capsule triggers cron some other way. |
| `WP_CRON_TRIGGER_INTERVAL_SECONDS` | `300` | Seconds between internal `wp-cron.php` triggers. |
| `SESSION_COOKIE_SECURE` | `1` | PHP `session.cookie_secure`. Set to `0` for local HTTP development. |
| `CSP_HEADER` | permissive default | Full `Content-Security-Policy` header value. Set to empty string to disable. |
| `DEBUG_HEADERS` | `false` | Set to `true` to expose `X-Cache` response header (reveals cache HIT/MISS/BYPASS). |

Default CSP:
```
default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: https:; frame-ancestors 'self';
```

---

### Nginx Customisation

#### `NGINX_EXTRA_CONF`

Raw nginx config injected into the `server {}` block before the PHP handler. Useful for custom proxy rules, headless WordPress API routes, WooCommerce custom endpoints.

```
NGINX_EXTRA_CONF=location /custom-api/ { proxy_pass http://internal-service:8080/; }
```

---

### Prometheus Metrics (Build-time)

| Variable | Default | Description |
|---|---|---|
| `NGINX_EXPORTER_VERSION` | `1.4.0` | Build-time: nginx-prometheus-exporter version |
| `FPM_EXPORTER_VERSION` | `2.2.0` | Build-time: php-fpm_exporter version |
| `TARGETARCH` | `amd64` | Build-time: target CPU architecture (`amd64`, `arm64`) |
| `BASE_IMAGE` | none (required) | Build-time: set from the track by `build.sh` |
| `MIN_PHP_VERSION` | none (required) | Build-time: set from the track by `build.sh`; the build fails on an older PHP |

---

## Prometheus Metrics

The container exposes two Prometheus metrics ports. No sidecar required.

| Port | Exporter | Key metrics |
|---|---|---|
| `9113` | nginx-prometheus-exporter | `nginx_connections_active`, `nginx_http_requests_total`, `nginx_connections_waiting` |
| `9253` | php-fpm_exporter | `phpfpm_listen_queue`, `phpfpm_max_children_reached_total`, `phpfpm_active_processes`, `phpfpm_slow_requests_total` |

WordPress application metrics (post counts, user counts, autoloaded options, `wp_cron_trigger_*`) are available at `http://127.0.0.1:8080/wp-metrics` from inside the container only. The script lives at `/usr/share/wp-runtime/wp-metrics.php`, outside the docroot, so a volume over `/var/www/html` does not hide it.

**Recommended Prometheus alerts:**

```yaml
- alert: FPMWorkersExhausted
  expr: phpfpm_listen_queue > 0
  for: 1m

- alert: FPMMaxChildrenHit
  expr: increase(phpfpm_max_children_reached_total[5m]) > 0

- alert: FPMNoIdleWorkers
  expr: phpfpm_idle_processes == 0
  for: 2m

- alert: WordPressAutoloadBloat
  expr: wordpress_autoloaded_options_bytes > 5e6
```

---

## Redis Object Cache

The **PhpRedis** C extension is baked into this image (see the `pecl install redis`
layer in the `Dockerfile`). It is significantly faster than the pure-PHP Predis
client because every `wp_cache_*` and transient call is a Redis round-trip, and
PhpRedis does the protocol/serialization work in C. To use Redis for object caching:

1. Install and activate the [Redis Cache](https://wordpress.org/plugins/redis-cache/) plugin.
2. Set constants via `WORDPRESS_CONFIG_EXTRA`:
   ```
   WORDPRESS_CONFIG_EXTRA=define('WP_REDIS_CLIENT', 'phpredis');
   define('WP_REDIS_HOST', getenv('REDIS_HOST'));
   define('WP_REDIS_PORT', 6379);
   define('WP_REDIS_PREFIX', 'mysite_');
   define('WP_REDIS_TIMEOUT', 1);
   define('WP_REDIS_READ_TIMEOUT', 1);
   ```

> **Client selection:** the Redis Cache drop-in auto-selects PhpRedis when the
> extension is present, so `WP_REDIS_CLIENT` is optional — but setting it explicitly
> documents intent and prevents a silent fall back to Predis if the extension ever
> fails to load.

> **Fail fast:** keep `WP_REDIS_TIMEOUT`/`WP_REDIS_READ_TIMEOUT` low (1s). Because
> Redis sits on the critical path of every request, a slow/unreachable Redis should
> error quickly rather than hang PHP-FPM workers. (These are already the drop-in
> defaults; setting them is belt-and-suspenders.)

> **Note:** the free Redis Cache drop-in opens a fresh (non-persistent) connection
> per request for single-node setups — `WP_REDIS_PERSISTENT`/`pconnect` only applies
> to its cluster path. The per-request `connect()` to a local Redis is one cheap
> round-trip; persistent connections are an Object Cache Pro feature.

> **Multi-tenancy:** Always set `WP_REDIS_PREFIX` to a unique value per site when multiple sites share a Redis instance. Without it, two WordPress sites will corrupt each other's object cache.

---

## Startup Script Layout

| Script | Purpose |
|---|---|
| `run.sh` | Orchestrates startup; supervises nginx, exporters, and php-fpm |
| `scripts/configure_wordpress_custom_ini.sh` | Merges `WORDPRESS_CUSTOM_INI` with defaults |
| `scripts/configure_wordpress_fpm_conf.sh` | Merges `WORDPRESS_FPM_CONF` with defaults |
| `scripts/configure_nginx_overrides.sh` | Generates all dynamic nginx config fragments |
| `scripts/lib/merge_and_write_config.sh` | Shared awk-based merge logic |

---

## Optimisations Included

- **OPcache**: reduces CPU usage on repeated requests
- **Gzip compression**: reduces response sizes by 60–80%
- **Static file caching**: 30-day browser cache for assets; 1h for XML/txt
- **FastCGI page cache**: configurable TTL (default 60s), bypassed for logged-in users, carts, admin
- **Security headers**: HSTS, CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, X-Permitted-Cross-Domain-Policies
- **PHP execution blocked** in uploads, cache, and upgrade directories
- **Sensitive files blocked**: `wp-config.php`, `debug.log`, `.env`, `.git`, `wp-config-sample.php`, plugin/theme readme files, `wp-includes/*.php`
- **Rate limiting**: three configurable zones (normal, protected, API) plus per-IP connection limit, keyed on the real client IP behind Traefik/Cloudflare
- **Cloudflare-aware real IP**: edge ranges baked at build so XFF recursion resolves the true visitor IP, preventing spurious 429s
- **Prometheus metrics**: in-container nginx and PHP-FPM exporters, no sidecar required
