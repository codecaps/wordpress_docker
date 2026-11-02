# WordPress runtime images

This repository builds the PHP runtime every Code Capsules WordPress capsule runs on. The image is
a PHP runtime, not a WordPress release: WordPress core belongs to the capsule's volume (default
capsules mount `/var/www/html`; the upstream entrypoint copies core in only when the volume is
empty, and WordPress updates itself from then on) or to the capsule's repo (git capsules).

Nginx acts as a reverse proxy in front of PHP-FPM, both running in the same container, on top of
the official `wordpress:php<minor>-fpm` image. Out of the box a capsule gets a full-page cache
that is purged when content changes, a PHP-FPM pool sized to the container, hardened nginx and
WordPress defaults, WP-CLI, logs in the platform log viewer, and Prometheus exporters. Everything
is tunable through environment variables.

---

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | The runtime. Requires `--build-arg BASE_IMAGE` and `--build-arg MIN_PHP_VERSION` (no defaults). |
| `tracks/php<minor>.env` | One track per PHP minor: `BASE_IMAGE` (digest-pinned), `MIN_PHP_VERSION`, `REVISION`. |
| `build.sh` / `push.sh` | Build / push one track. |
| `tests/smoke.sh` | Smoke test for a built image (installs WordPress with WP-CLI and exercises cache, purge, limits, headers, shutdown, the sized pool and the in-flight cap). |
| `tests/run.sh` | Shell unit tests for the cgroup detection, the sizing model and the configure scripts (`bash tests/run.sh`, bash 4+; on macOS use Homebrew's). |
| `run.sh`, `scripts/` | Container startup: generate config from env, start php-fpm then nginx, supervise, shut down gracefully. |
| `nginx.conf`, `default.conf`, `nginx/snippets/` | nginx configuration (static parts; the dynamic parts are generated at startup). |
| `runtime/` | Files installed to `/usr/share/wp-runtime`: the platform prepend and the runtime mu-plugin. |
| `wp-metrics.php` | WordPress application metrics endpoint (internal). |
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
   older PHP unacceptable. Any change to the image contents (nginx, scripts, runtime files) also
   needs a `REVISION` bump once the previous revision has been pushed.

   Renovate (`renovate.json`) opens these digest PRs every Monday morning, one per track. It does
   not touch `REVISION`: **the PR author must bump `REVISION` in the same PR** — the `runtime`
   workflow fails a `BASE_IMAGE` change without one, and builds + smoke-tests every track (it
   never pushes).
2. Build: `./build.sh 8.4` (prints the immutable ref).
3. Smoke: `tests/smoke.sh <ref> <MIN_PHP_VERSION>` — every check must `PASS`.
4. Push: `./push.sh 8.4` (immutable tag, then the moving alias).
5. Bump the tag in capsule-api's `WORDPRESS_RUNTIME_TAGS` and deploy it.
6. Run capsule-api's `redeploy-wordpress-capsules` job to roll the new tag to every capsule on
   that track.

Third-party binaries (Prometheus exporters, WP-CLI, PhpRedis) are pinned by version and checksum
in the `Dockerfile`; bump the `ARG`s together with the published checksums.

---

## Container Startup

`run.sh` is executed on container start. It:

1. Reads the container's cgroup CPU and memory limits and sizes PHP, PHP-FPM and nginx to them
   (logged as `[sizing]` lines; see [Resource-aware sizing](#resource-aware-sizing))
2. Writes the sized PHP ini defaults merged with `$WORDPRESS_CUSTOM_INI` to `$PHP_INI_DIR/conf.d/zz-custom.ini`
3. Writes the sized PHP-FPM pool config merged with `$WORDPRESS_FPM_CONF` to `/usr/local/etc/php-fpm.d/zzz-custom.conf`
4. Generates nginx config fragments from environment variables and the sizing (worker count, PHP in-flight cap, rate limits, cache, headers, ...)
5. Validates the configuration with `nginx -t`. A broken `NGINX_EXTRA_CONF` is disabled (and logged) instead of crash-looping the pod.
6. Starts nginx immediately with a "starting up" holding page (HTTP 503 + `Retry-After: 5` on every
   path, `/healthz` included), then php-fpm; on a first boot the upstream entrypoint copies WordPress
   core onto the volume before FPM listens, which can take a minute on a network volume. The holding
   page is dropped the moment FPM listens. TCP probes therefore pass at once (no startup-probe kill
   during the copy) and HTTP probes stay honest. The exporters run as `www-data`; the internal
   wp-cron trigger starts last
7. On `SIGTERM`/`SIGQUIT` shuts nginx and php-fpm down gracefully (in-flight requests finish, bounded by `SHUTDOWN_TIMEOUT_SECONDS`, default 20) and exits 0; exits non-zero if nginx or php-fpm dies

`/healthz` is answered by PHP-FPM's ping path, so it fails when FPM is down, and returns 503 while
the holding page is up.

nginx access and error logs and php-fpm's error log go to the container's stdout/stderr, i.e. the
platform log viewer. Nothing is written to log files inside the container. (PHP-FPM's slow log is
off: it needs `ptrace`, which the capsule's security context forbids; nginx's access log carries
`rt=` and `urt=` per request instead.)

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

#### Platform defaults (the prepend)

A small PHP file (`/usr/share/wp-runtime/prepend.php`, wired in as `auto_prepend_file`) runs before
every request. It marks the request as HTTPS when Traefik says so, defines a few hardened defaults
for constants the site has **not** defined itself, and loads the runtime mu-plugin. A constant
defined in `wp-config.php` or `WORDPRESS_CONFIG_EXTRA` always wins.

| Variable | Default | Constant / effect |
|---|---|---|
| `WP_RUNTIME_PREPEND_ENABLED` | `true` | `false` turns the whole prepend off (no defaults, no mu-plugin) |
| `WP_DISABLE_WP_CRON` | follows `WP_CRON_TRIGGER_ENABLED` | `DISABLE_WP_CRON`: WordPress's page-load cron spawner is off because the runtime triggers cron internally |
| `WP_DISALLOW_FILE_EDIT` | `true` | `DISALLOW_FILE_EDIT`: the theme/plugin file editors are off (a compromised admin account would otherwise be code execution) |
| `WP_MEMORY_LIMIT` | the sized php.ini `memory_limit` (128M below 1.5 GiB, else 256M) | `WP_MEMORY_LIMIT`. WordPress raises `memory_limit` to this when it is higher, so it follows the container-sized cap instead of defeating it (WordPress's own default is 40M) |
| `WP_MAX_MEMORY_LIMIT` | sized: twice the request limit where the container can hold it (128M on Basic, 256M on Standard and Premium, 512M from 2 GiB) | `WP_MAX_MEMORY_LIMIT` (admin screens, image editing, upgrades, cron). The runtime mu-plugin also applies it to an administrator's admin-ajax, admin-post and REST requests, which core leaves at the front-end limit |
| `WP_REDIS_HOST` (+ `WP_REDIS_PORT`, `WP_REDIS_PASSWORD`, `WP_REDIS_DATABASE`, `WP_REDIS_PREFIX`) | unset | When set, the Redis Cache plugin's constants are defined from these (see [Redis Object Cache](#redis-object-cache)) |
| `WP_RUNTIME_MU_PLUGIN_ENABLED` | `true` | Loads the runtime mu-plugin: page-cache purge on content changes, "Purge page cache" in the admin bar, `wp cc cache purge|status` |

#### `WORDPRESS_CONFIG_EXTRA`

Arbitrary PHP injected into `wp-config.php` by the upstream WordPress Docker entrypoint (it is
evaluated on every request, so changes apply on redeploy). Use this for WordPress constants:

```
WORDPRESS_CONFIG_EXTRA=define('FORCE_SSL_ADMIN', true);
define('WP_AUTO_UPDATE_CORE', 'minor');
```

#### `WORDPRESS_CUSTOM_INI`

Custom PHP ini settings merged **over** the sized defaults (a key you set replaces the default;
keys you don't set keep their sized value; unknown keys are appended). The defaults already
include a production php.ini, OPcache sized to the container (`validate_timestamps=1` /
`revalidate_freq=60` so plugin updates are picked up), a container-sized `memory_limit`,
`max_input_vars = 3000` and a large realpath cache. Nothing needs to be set for a capsule to be
correctly sized; this is for the exceptions:

```ini
; A plugin that needs more than the sized per-request limit:
memory_limit = 512M

; Theme with very large forms:
max_input_vars = 5000

; Immutable image where plugins/themes never update at runtime:
opcache.validate_timestamps = 0
```

> **Note:** `upload_max_filesize` and `post_max_size` default to `MAX_UPLOAD_SIZE`. Override here only if you need them to differ from the nginx limit.

> **Note:** a `memory_limit` set here is fed back into the sizing: the worst case of every worker
> grows with it, so the worker pool shrinks accordingly (see the `[sizing]` boot log). The prepend's
> `WP_MEMORY_LIMIT` / `WP_MAX_MEMORY_LIMIT` defaults follow it too.

#### `WORDPRESS_FPM_CONF`

Custom PHP-FPM pool configuration, merged over the sized defaults the same way (per `[section]`).
Only needed to pin a pool by hand. A `pm.max_children` set here re-derives `pm.start_servers` /
`pm.min_spare_servers` / `pm.max_spare_servers` and the nginx in-flight cap from the pinned value
(PHP-FPM refuses to start when `max_spare_servers` exceeds `max_children`), unless you set those
too:

```ini
[www]
pm = static
pm.max_children = 16
request_terminate_timeout = 60s
```

php-fpm's own access log is off (nginx logs every request with the real client IP, timing and cache
status); PHP errors still go to the container's stderr. PHP-FPM listens on `127.0.0.1:9000` only.

Timeouts are wall-clock: `request_terminate_timeout = 300s` in the pool (what WordPress budgets for
core and plugin upgrades, which a 0.07–0.25 vCPU pod needs), nginx `fastcgi_read_timeout` 300s for
`/wp-admin/*.php` and 120s for public requests. php.ini's `max_execution_time = 60` counts CPU time
on this build and never fires at a fraction of a vCPU.
`clear_env = no` is set so WordPress can read `WORDPRESS_DB_HOST` etc. via `getenv()`, which means
**all** environment variables are visible to PHP code. Do not inject secrets as env vars that
WordPress plugins should not access.

---

### Resource-aware sizing

Kubernetes enforces a capsule's scale with cgroup limits, but nothing inside the container reports
them: `nproc` and `/proc/meminfo` describe the *node*. The image therefore reads its own cgroup
(v2 or v1) at startup and derives the PHP, PHP-FPM and nginx defaults from the real limits, so one
image is safe on the 0.28 GB Basic plan and uses all of a multi-GB custom one. The sizing is logged
on every boot:

```
[sizing] Container limits (cgroup): memory=953M cpu=250m
[sizing]   php: memory_limit=128M opcache=160M interned_strings=16M
[sizing]   php-fpm: max_children=3 (memory-bound=10, cpu-bound=3, worker_budget=64M, reserved=139M) start=1 spare=1-2
[sizing]   nginx: worker_processes=1 max_inflight_php_requests=12
```

The model (`scripts/lib/resource_sizing.sh`), all in MiB:

| Setting | Rule | Why |
|---|---|---|
| `memory_limit` | 128M below 1.5 GiB, 256M above | Per-request cap. Front-end requests peak at 40–70 MB even on heavy sites (measured under load on a 15-plugin multilingual site); admin work gets `WP_MAX_MEMORY_LIMIT` (twice this, at least 256M). |
| `opcache.memory_consumption` | memory ÷ 6, clamped 96–256, rounded to 16 | Shared segment, charged to the container only as pages are touched, so erring large costs nothing; a full OPcache recompiles files on every request, which a 0.07-CPU pod cannot afford. Core + a typical plugin set compiles to 40–120 MB. |
| `opcache.interned_strings_buffer` | 8 / 16 / 32 by OPcache size | |
| reserved | 80 + memory ÷ 16 | nginx, the two exporters, the FPM master, and page-cache headroom (the pod idles at ~70–80 MB). |
| worker budget | `memory_limit` ÷ 2 (`PHP_WORKER_MEMORY_MB`) | Private memory budgeted per FPM worker. Measured 28–48 MB average / 60 MB peak per worker under load; 35–50 MB for a fresh install on this platform. |
| `pm.max_children` | min( (memory − reserved − opcache) ÷ worker budget, ceil(CPU × `PHP_FPM_WORKERS_PER_CPU`) ), clamped 3–64 | The memory bound keeps the pool inside the container; the CPU bound stops forking workers the quota cannot run (they only add memory and contention). The floor of 3 is from the Basic plan: with 2 workers, two slow requests stalled the site, and the internal cron trigger takes a worker every minute. |
| `pm.start_servers` / spare | ⅓ / ¼ – ½ of `max_children` | |
| `WP_MAX_MEMORY_LIMIT` | memory − reserved − opcache, clamped to `memory_limit` – 2 × `memory_limit` | What WordPress raises to for admin work. On Basic that is the request limit itself: one admin request at WordPress's default 256M would be most of the pod. |
| ImageMagick `memory` / `map` limits | 2 × worker budget (64–256 MiB) / twice that (`MAGICK_MEMORY_LIMIT`, `MAGICK_MAP_LIMIT`) | The pixel cache lives outside PHP's heap, so `memory_limit` never sees it, but the cgroup does: a 24 MP photo is ~150 MB before any thumbnail. Past the limit ImageMagick spills to a temp file instead of growing. |
| nginx `worker_processes` | ceil(CPU), clamped 1–4 (`NGINX_WORKER_PROCESSES` overrides) | `auto` starts one worker per *host* core. |
| PHP capacity cap | `pm.max_children` × 4 (`PHP_INFLIGHT_PER_WORKER`), clamped 8–1024, as upstream `max_conns` | FastCGI connections nginx keeps open to the pool (active plus queued) before answering `503` + `Retry-After` with a holding page. Past the FPM pool every request waits in a queue; without a cap a burst queues thousands of requests that each hold a worker for a minute, and the capsule stays unresponsive for hours after the burst. The queue is shallow on purpose: throughput is CPU-bound whatever its depth, so a deeper queue only makes admitted visitors wait longer. Cache hits and static files never open an upstream connection, so they keep being served while the pool is saturated; the health check and the loopback cron trigger use an uncapped upstream and queue instead. |

What that produces for the standard plans:

| Plan | Memory | CPU | `memory_limit` | `WP_MAX_MEMORY_LIMIT` | opcache | `pm.max_children` | capacity cap | nginx workers |
|---|---|---|---|---|---|---|---|---|
| Basic | 0.28 GB | 7% | 128M | 128M | 96M | 3 (floor) | 12 | 1 |
| Standard | 0.6 GB | 15% | 128M | 256M | 96M | 3 (floor) | 12 | 1 |
| Premium | 1 GB | 25% | 128M | 256M | 160M | 3 | 12 | 1 |
| Custom | 2 GB | 1 | 256M | 512M | 256M | 12 | 48 | 1 |
| Custom | 4 GB | 2 | 256M | 512M | 256M | 24 | 96 | 2 |
| Custom | 8 GB | 4 | 256M | 512M | 256M | 48 | 192 | 4 |

> On Basic the floor of 3 exceeds the memory budget (the boot log prints a WARNING): fine for a
> light site, but WordPress with WooCommerce or a page builder should run on Premium or above. On
> Standard only the CPU quota is below the floor (the log says so). At 0.07–0.25 vCPU an uncached
> page costs seconds of CPU whatever the worker count; capacity on those plans comes from the page
> cache, and the capacity cap turns "OOM-kill and restart" into "answer 503 past capacity and
> recover instantly" while cached pages keep being served.

Tuning knobs, rarely needed since any output can also be pinned directly through
`WORDPRESS_CUSTOM_INI` / `WORDPRESS_FPM_CONF`:

| Variable | Default | Description |
|---|---|---|
| `PHP_WORKER_MEMORY_MB` | `memory_limit` ÷ 2 | Private memory budgeted per FPM worker. Raise it for sites whose requests routinely peak high (WooCommerce with many extensions); lower it for lean sites to get more workers. |
| `PHP_FPM_WORKERS_PER_CPU` | `12` | Worker oversubscription per core. PHP is CPU-bound once OPcache is warm, so more only helps if requests spend most of their time waiting on a slow database or external API. |
| `PHP_INFLIGHT_PER_WORKER` | `4` | Queued-plus-active PHP requests allowed per worker before nginx answers `503`. Raise it if your pages are fast and you would rather queue than shed. |
| `MAGICK_MEMORY_LIMIT` / `MAGICK_MAP_LIMIT` | from the sizing | ImageMagick resource limits; set either to override the derived value. |
| `NGINX_WORKER_PROCESSES` | ceil(CPU), 1–4 | nginx worker count. |

Without a cgroup limit (local `docker run` without `--memory`/`--cpus`) the sizing falls back to
the host's memory and CPU count and says so in the log. The sizing is also exported as
`cc_runtime_*` gauges on the internal metrics endpoint. Run the tests with `bash tests/run.sh`.

---

### Upload Size

#### `MAX_UPLOAD_SIZE`

Controls `client_max_body_size` in nginx **and** `upload_max_filesize` / `post_max_size` in PHP,
keeping them in sync. Default `64M`; accepts `<n>M` or `<n>G` (`64M`, `256M`, `1G`). Anything else
(`64MB`, `0`) is rejected with a log line and the default is used.

---

### Caching

The nginx FastCGI full-page cache is **on by default** for anonymous `GET`/`HEAD` requests, with a
60-second TTL, stale-while-revalidate, and bypass for logged-in users, commenters, carts and
checkout (WooCommerce/EDD cookies and paths), previews, search, REST, admin, any response that
sets a cookie, any response carrying WordPress's own no-cache headers (`nocache_headers()`; anonymous
404s are the exception and are cached for a minute), and any page WordPress declares uncacheable
(`DONOTCACHEPAGE`, which WooCommerce, membership and login plugins define; the runtime mu-plugin
relays it to nginx when the response is produced, so a plugin that defines it and exits is covered
too). Only pages and canonical 301s are stored, never a 302 (geolocation and language redirects are
per visitor). The runtime mu-plugin purges the whole cache when content changes (posts, pages,
comments, terms, menus, widgets, theme/plugin changes, relevant options), from the "Purge page
cache" admin-bar item, and via `wp cc cache purge`. Themes and plugins can `do_action('cc_cache_purge')`.

| Variable | Default | Description |
|---|---|---|
| `CACHE_TTL_SECONDS` | `60` | Cache TTL. `0` (or `off`/`false`) disables the page cache. |
| `CACHE_MAX_SIZE` | `512M` | Upper bound of the on-disk cache (`<n>M`/`<n>G`). |
| `CACHE_IGNORE_QUERY_PARAMS` | unset | JSON array of query-parameter name patterns to ignore in the cache key, e.g. `'["utm_*","fbclid"]'` (`*` matches any characters; allowed: `A–Z a–z 0–9 _ * -`). |
| `CACHE_SKIP_EMPTY` | `true` | Never store an empty-bodied 200 (a blank page from a failed output buffer). |
| `DEBUG_HEADERS` | `false` | `true` adds `X-Cache: HIT|MISS|BYPASS|EXPIRED|...` to PHP responses. |

> **Which TTL should I use?**
>
> - The default `60` is right for most sites: visitors see changes within a minute even if a
>   purge is missed, and busy pages are rendered at most once a minute.
> - Raise it (`600`, `3600`) for mostly static sites; the purge-on-publish keeps content fresh.
> - Set `CACHE_TTL_SECONDS=0` for real-time dashboards, membership/LMS sites with
>   per-visitor content that does not set cookies, or when a WordPress cache plugin manages page caching.

Cache key normalisation example with `CACHE_IGNORE_QUERY_PARAMS='["utm_*"]'`:

| Request | Cache behavior |
|---|---|
| `GET /page/1?utm_term=xyz` | MISS — rendered and stored |
| `GET /page/1?utm_term=abc` | HIT — same cache entry as above |
| `GET /page/1` | HIT — same cache entry |
| `GET /page/1?page=2&utm_term=xyz` | Key includes `page=2` only (utm params stripped from key) |

The cache key is `<scheme>|<method>|<host>|<request_uri>`; the purge endpoint (`/.cc-cache-purge`,
loopback only, token protected) accepts an exact key, a `<prefix>*` or `*`.

---

### Rate Limiting

| Variable | Default | Description |
|---|---|---|
| `RATE_LIMIT_NORMAL_ROUTES_RPM` | `300` | Req/min per IP for public routes (burst 100) |
| `RATE_LIMIT_PROTECTED_ROUTES_RPM` | `120` | Req/min per IP for `/wp-admin/*.php` incl. `admin-ajax.php` (burst 60) |
| `RATE_LIMIT_LOGIN_ROUTES_RPM` | `30` | Req/min per IP for `wp-login.php` (burst 10), `wp-comments-post.php` (burst 5), `xmlrpc.php` (burst 3) |
| `RATE_LIMIT_API_ROUTES_RPM` | `300` | Req/min per IP for `/wp-json/` (burst 100; the block editor makes many REST calls) |
| `RATE_LIMIT_MAX_CONN_PER_IP` | `100` | Max concurrent connections per IP |

Static assets are never rate-limited. All limits are **per client IP**, resolved from
`X-Forwarded-For` (see below). If the true client IP is not resolved correctly, every visitor
shares one bucket and trips these limits with spurious `429`s; the `limiting requests` log lines
are in the container logs.

In addition to these per-IP limits, PHP has a capsule-wide capacity cap sized to the PHP-FPM pool
(see [Resource-aware sizing](#resource-aware-sizing)); requests past it get `503` with
`Retry-After: 5` and a holding page (`no live upstreams` in the error log), while cached pages and
static files keep being served.

---

### Real Client IP & Cloudflare

nginx resolves the real client IP from `X-Forwarded-For` (`real_ip_recursive on`) and uses it for
all rate limits, the per-IP connection limit, access logs, and the IP passed to WordPress
(`REMOTE_ADDR` / `X-Real-IP`). Trusted hops:

| Variable | Default | Description |
|---|---|---|
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` | Intermediaries whose `X-Forwarded-For` is believed (Traefik / k8s LB / VPC). Space- or comma-separated; narrow it to the Traefik pod CIDR where possible. |

plus **Cloudflare's published edge ranges**, baked into the image at build time from
`cloudflare.com/ips-v4` and `ips-v6` (falling back to `cloudflare_ips.fallback.conf` with a
warning if the fetch fails). Rebuild the image to refresh them.

> ⚠️ **Security:** Trusting Cloudflare's *public* ranges means a client that can reach the origin
> **directly** (bypassing Cloudflare) could forge `X-Forwarded-For`. Lock the origin to Cloudflare
> only: edge IP allowlist at your load balancer, Authenticated Origin Pulls, or a Cloudflare Tunnel.
> Traefik itself must forward `X-Forwarded-For` from Cloudflare (`forwardedHeaders.trustedIPs`);
> check the access log's `xff=... realip=...` fields on a test capsule.

---

### Security & Behaviour

| Variable | Default | Description |
|---|---|---|
| `XMLRPC_ENABLED` | `false` | Set to `true` to enable XML-RPC (Jetpack, WP mobile app, external publishing) |
| `DISABLE_PUBLIC_WP_CRON` | `true` | Restrict `wp-cron.php` to `127.0.0.1`. Triggered internally instead — see `WP_CRON_TRIGGER_ENABLED`. |
| `WP_CRON_TRIGGER_ENABLED` | `true` | `run.sh` calls `wp-cron.php` over `127.0.0.1` on an interval. Set to `false` only if the capsule triggers cron some other way. |
| `WP_CRON_TRIGGER_INTERVAL_SECONDS` | `60` | Seconds between internal `wp-cron.php` triggers. |
| `SESSION_COOKIE_SECURE` | `1` | PHP `session.cookie_secure`. Set to `0` for local HTTP development. |
| `CSP_HEADER` | see below | Full `Content-Security-Policy` value. Empty string disables it. Quotes (`"`), `$` and backslashes are rejected (default used). |
| `HSTS_HEADER` | `max-age=31536000` | `Strict-Transport-Security` value, sent only on HTTPS requests. Empty string disables it. Add `; includeSubDomains` yourself only if every subdomain of the domain is HTTPS. |
| `NGINX_WORKER_PROCESSES` | from the CPU quota (1–4) | nginx worker count (see [Resource-aware sizing](#resource-aware-sizing) for the PHP knobs). |
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | How long a graceful shutdown waits for in-flight requests before terminating nginx/php-fpm. |
| `FPM_STARTUP_TIMEOUT_SECONDS` | `600` | How long the holding page is served while waiting for php-fpm to listen on a slow first boot. |

Default CSP:
```
default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: https:; connect-src 'self' https: wss:; frame-ancestors 'self';
```

Security headers are set with the headers-more module, so they are present on every response
(static assets and `NGINX_EXTRA_CONF` locations included).

> **Email:** the image ships no mail transport, so `wp_mail()` (password resets, WooCommerce order
> mails, form notifications) does not deliver until the site has an SMTP plugin configured with a
> mail provider. A platform relay driven by `SMTP_*` variables is on the roadmap.

---

### Nginx Customisation

#### `NGINX_EXTRA_CONF`

Raw nginx config injected into the `server {}` block before the PHP handler. Useful for custom
proxy rules, headless WordPress API routes, WooCommerce custom endpoints.

```
NGINX_EXTRA_CONF=location /custom-api/ { proxy_pass http://internal-service:8080/; }
```

If the fragment does not pass `nginx -t`, the container logs the error, disables the fragment and
starts without it, so a typo cannot take the site down.

---

### Build-time variables

| Variable | Default | Description |
|---|---|---|
| `BASE_IMAGE` | none (required) | Set from the track by `build.sh` |
| `MIN_PHP_VERSION` | none (required) | Set from the track by `build.sh`; the build fails on an older PHP |
| `TARGETARCH` | `amd64` | Target CPU architecture (`amd64`, `arm64`) |
| `NGINX_EXPORTER_VERSION` / `_SHA256_*` | `1.5.3` | nginx-prometheus-exporter version and release checksums |
| `FPM_EXPORTER_VERSION` / `_SHA256_*` | `2.2.0` | php-fpm_exporter version and release checksums |
| `WP_CLI_VERSION` / `WP_CLI_SHA512` | `2.12.0` | WP-CLI version and checksum |
| `PHPREDIS_VERSION` | `6.3.0` | PhpRedis PECL version |

---

## WP-CLI

`wp` is installed in the image (run it as `wp --allow-root --path=/var/www/html ...` from a shell
in the container). Besides the usual commands (`wp core version`, `wp plugin list`,
`wp search-replace`, `wp cron event run --due-now`), the runtime adds:

- `wp cc cache status` — whether the page cache is on, and its TTL
- `wp cc cache purge` — purge the page cache

The platform prepend applies to the CLI too, so `wp` sees the same constants as the site.

---

## Prometheus Metrics

The container exposes two Prometheus metrics ports (the exporters run as `www-data`). No sidecar required.

| Port | Exporter | Key metrics |
|---|---|---|
| `9113` | nginx-prometheus-exporter | `nginx_connections_active`, `nginx_http_requests_total`, `nginx_connections_waiting` |
| `9253` | php-fpm_exporter | `phpfpm_listen_queue`, `phpfpm_max_children_reached_total`, `phpfpm_active_processes`, `phpfpm_slow_requests_total` |

WordPress application metrics (post counts, user counts, autoloaded options, the installed core
version, `wp_cron_trigger_*`, and the sizing in effect as `cc_runtime_container_memory_bytes`,
`cc_runtime_container_cpu_millicores`, `cc_runtime_fpm_max_children`,
`cc_runtime_php_max_inflight_requests`, `cc_runtime_php_memory_limit_bytes`) are available at
`http://127.0.0.1:8080/wp-metrics` from inside the container only. The script lives at `/usr/share/wp-runtime/wp-metrics.php`, outside the docroot,
so a volume over `/var/www/html` does not hide it.

> The cluster's Prometheus must be told to scrape these ports (a PodMonitor on the WordPress pod
> labels); nothing scrapes them by default.

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

The **PhpRedis** C extension is baked into this image. To use Redis for object caching:

1. Create a Redis capsule and set `WP_REDIS_HOST` (and `WP_REDIS_PASSWORD` if needed) on the
   WordPress capsule. The prepend then defines `WP_REDIS_HOST`, `WP_REDIS_PORT` (6379),
   `WP_REDIS_PREFIX` (defaults to the database name, so sites sharing one Redis never collide),
   `WP_REDIS_CLIENT=phpredis` and 1-second timeouts.
2. Install and activate the [Redis Cache](https://wordpress.org/plugins/redis-cache/) plugin and
   click *Enable Object Cache* (or `wp redis enable`).

Override any constant in `WORDPRESS_CONFIG_EXTRA`; the prepend never redefines a constant the
site defines itself.

> **Fail fast:** keep `WP_REDIS_TIMEOUT`/`WP_REDIS_READ_TIMEOUT` low (1s). Redis sits on the
> critical path of every request, so a slow/unreachable Redis should error quickly rather than hang
> PHP-FPM workers.

---

## Startup Script Layout

| Script | Purpose |
|---|---|
| `run.sh` | Orchestrates startup; loads the sizing, supervises nginx, exporters, php-fpm and the cron trigger; graceful shutdown |
| `scripts/configure_wordpress_custom_ini.sh` | Merges `WORDPRESS_CUSTOM_INI` with the sized defaults (memory_limit, OPcache, prepend) |
| `scripts/configure_wordpress_fpm_conf.sh` | Merges `WORDPRESS_FPM_CONF` with the sized pool |
| `scripts/configure_nginx_overrides.sh` | Generates all dynamic nginx config fragments (incl. `worker_processes` and the PHP in-flight cap) and the cache state for the mu-plugin |
| `scripts/lib/container_resources.sh` | Reads the container's cgroup (v1/v2) CPU and memory limits |
| `scripts/lib/resource_sizing.sh` | Derives the PHP / PHP-FPM / nginx sizing from those limits (and from pinned overrides) |
| `scripts/lib/runtime_env.sh` | Shared validators |
| `scripts/lib/merge_and_write_config.sh` | Shared awk-based merge logic |
| `tests/run.sh` | Shell test suite for the detection, the sizing model and the configure scripts |
| `runtime/prepend.php` | Platform prepend (HTTPS, hardened constants, loads the mu-plugin) |
| `runtime/mu-plugins/code-capsules.php` | Runtime mu-plugin (cache purge, admin bar, WP-CLI commands) |

---

## Optimisations Included

- **Full-page cache** on by default with purge-on-publish, stale-while-revalidate, WooCommerce-aware bypass rules and `DONOTCACHEPAGE` honoured
- **Resource-aware sizing**: PHP `memory_limit`, OPcache, the PHP-FPM worker pool and nginx workers are derived from the container's real cgroup limits, so the container cannot over-commit its memory and be OOM-killed under load; production `php.ini`
- **Load shedding**: a capsule-wide cap on PHP-FPM connections sized to the pool answers `503` + `Retry-After` past capacity instead of queueing a burst for minutes, while cached pages and static files keep flowing; ImageMagick bounded to the sizing so a huge upload cannot OOM-kill the pod
- **Gzip compression**: reduces response sizes by 60–80%
- **Static file caching**: 30-day browser cache for assets; 1h for XML/txt
- **Security headers** on every response: HSTS (HTTPS only), CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, X-Permitted-Cross-Domain-Policies
- **Hardened WordPress defaults**: file editors off, sane memory limits, cron run by the platform
- **PHP execution blocked** in uploads, cache, and upgrade directories; drop-ins and `wp-includes` not requestable
- **Sensitive files blocked** (404): `wp-config.*`, dumps and backups (`.sql`, `.bak`, `.old`...), `debug.log`, `.env`, `.git`, readme/changelog files
- **Rate limiting**: four configurable zones (public, wp-admin, login/comments/xmlrpc, REST) plus a per-IP connection limit, keyed on the real client IP behind Traefik/Cloudflare
- **Cloudflare-aware real IP**: edge ranges baked at build so XFF recursion resolves the true visitor IP
- **Graceful deploys**: a 503 holding page while PHP-FPM starts (no 502s, no probe kills on first boot); shutdown finishes in-flight requests
- **Logs in the platform**: nginx and PHP logs on stdout/stderr
- **Prometheus metrics**: in-container nginx and PHP-FPM exporters plus WordPress metrics
- **WP-CLI** in the image
