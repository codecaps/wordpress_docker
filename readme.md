# WordPress runtime images

This repository builds the PHP runtime every Code Capsules WordPress capsule runs on. The image is
a PHP runtime, not a WordPress release: WordPress core belongs to the capsule's volume (default
capsules mount `/var/www/html`; the upstream entrypoint copies core in only when the volume is
empty, and WordPress updates itself from then on) or to the capsule's repo (git capsules, see
[`git/`](git/README.md)).

Nginx acts as a reverse proxy in front of PHP-FPM, both running in the same container, on top of
the official `wordpress:php<minor>-fpm` image. Out of the box a capsule gets a full-page cache
that is purged when content changes, PHP, PHP-FPM and nginx sized to the container's cgroup
limits, a capacity cap that answers 503 past capacity instead of queueing a burst, hardened nginx
and WordPress defaults, an internal wp-cron trigger, WP-CLI, logs in the platform log viewer, and
Prometheus exporters. Everything is tunable through environment variables.

---

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | The runtime image. Requires `--build-arg BASE_IMAGE` and `--build-arg MIN_PHP_VERSION` (no defaults; `build.sh` sets both from the track). |
| `tracks/php<minor>.env` | One track per PHP minor: `BASE_IMAGE` (digest-pinned), `MIN_PHP_VERSION`, `REVISION`. |
| `build.sh` / `push.sh` | Build / push one track (see [Releasing a runtime](#releasing-a-runtime)). |
| `tools/registry_guard.sh` | Host-side helper for `push.sh` and `legacy/docker_push.sh`: asks the registry whether a tag already exists. Not part of any image. |
| `run.sh` | The container entrypoint (see [Container startup](#container-startup)). |
| `scripts/` | Startup scripts: size the container and generate the PHP, PHP-FPM and nginx config from the environment (see below). |
| `nginx.conf`, `default.conf`, `nginx/snippets/wp-fastcgi.conf` | The static nginx configuration. The dynamic parts are written to `/etc/nginx/conf.d/generated_*.conf` at startup. |
| `runtime/` | Installed to `/usr/share/wp-runtime`: the platform prepend, the runtime mu-plugin and nginx's holding pages (see below). |
| `wp-metrics.php` | WordPress application metrics endpoint (`:9254/metrics` on the pod network). |
| `cloudflare_ips.fallback.conf` | Snapshot of Cloudflare's edge ranges, used when the build-time fetch fails. |
| `tests/` | `run.sh` runs the shell unit tests (`test_*.sh`, helpers in `lib.sh`); `smoke.sh` tests a built image (see [Local development and tests](#local-development-and-tests)). |
| `.github/workflows/runtime.yml` | PR CI: the `REVISION` check, the unit tests, and a build + smoke test of every track. Never pushes. |
| `renovate.json` | Weekly digest updates of the tracks' `BASE_IMAGE`. |
| `docker_run.sh` | Run a locally built runtime against a MySQL on the host. |
| `git/` | Git capsule image: the runtime plus the capsule's repo (see [`git/README.md`](git/README.md)). |
| `legacy/` | Per-WordPress-version images for capsules not yet retrofitted (see [Legacy images](#legacy-images)). Delete once capsule-api's legacy image map is gone. |
| `docs/superpowers/` | Design spec, implementation plan, audit and roadmap, sizing review. Not part of the image. `.gitignore` ignores `specs`, so a new file under `specs/` needs `git add -f`. |

`.dockerignore` keeps `docs/`, `git/`, `legacy/`, `tests/`, `tools/`, `tracks/`, `.github/`,
`renovate.json` and `*.md` out of the runtime's build context.

### `scripts/` and `runtime/`

| File | Runs | Purpose |
|---|---|---|
| `scripts/configure_wordpress_custom_ini.sh` | startup | Merges `WORDPRESS_CUSTOM_INI` over the sized php.ini defaults (memory_limit, OPcache, uploads, the prepend) |
| `scripts/configure_wordpress_fpm_conf.sh` | startup | Merges `WORDPRESS_FPM_CONF` over the sized PHP-FPM pool |
| `scripts/configure_nginx_overrides.sh` | startup | Writes every dynamic nginx fragment (worker count, PHP capacity cap, rate limits, cache and cache key, headers, routes) and the cache state the mu-plugin reads |
| `scripts/lib/container_resources.sh` | startup | Reads the container's cgroup (v2 or v1) CPU and memory limits |
| `scripts/lib/resource_sizing.sh` | startup | Derives the PHP / PHP-FPM / nginx sizing from those limits (and from pinned overrides) |
| `scripts/lib/runtime_env.sh` | startup | Shared validators (results on stdout, log lines on stderr) |
| `scripts/lib/merge_and_write_config.sh` | startup | The awk merge of overrides over defaults (per key, per `[section]`) |
| `scripts/lib/wp_cron_trigger.sh` | cron trigger | Which sites the internal cron trigger requests, and how |
| `scripts/lib/cloudflare_ips.sh` | image build | Validates the Cloudflare edge ranges the `Dockerfile` fetches |
| `runtime/prepend.php` | every PHP request and WP-CLI command | Platform prepend: HTTPS behind the proxy, hardened and sized constants, Redis constants, the cron heartbeat, loads the mu-plugin |
| `runtime/mu-plugins/code-capsules.php` | every WordPress request | Runtime mu-plugin: page-cache purge, `DONOTCACHEPAGE` relay, admin memory, admin-bar item, `wp cc` commands |
| `runtime/html/starting.html`, `busy.html` | nginx | The 503 holding pages: while php-fpm starts, and past the PHP capacity cap |

### Where things live in the image

| Path | Contents |
|---|---|
| `/usr/run.sh`, `/usr/scripts/` | `run.sh` (the `ENTRYPOINT`) and `scripts/` |
| `/etc/nginx/` | `nginx.conf`, `conf.d/default.conf`, `snippets/wp-fastcgi.conf`; `conf.d/cloudflare_ips.conf` (written at build) and `conf.d/generated_*.conf` (written at startup) |
| `/usr/share/wp-runtime/` | `runtime/` and `wp-metrics.php`, outside the docroot so a volume over `/var/www/html` cannot hide them |
| `$PHP_INI_DIR/conf.d/zz-custom.ini` | php.ini defaults merged with `WORDPRESS_CUSTOM_INI` |
| `/usr/local/etc/php-fpm.d/zzz-custom.conf` | The pool merged with `WORDPRESS_FPM_CONF` (sorts after the upstream `zz-docker.conf`) |
| `/var/cache/nginx/wordpress/` | The page cache. It lives in the container, not on the volume, so it starts empty on every restart. |
| `/var/run/wp-runtime/` | State shared with PHP (`root:www-data`, 0750): the `starting` flag, `nginx-cache.env` (cache state and purge token), `cron-last-run` (the cron heartbeat), `nginx-t.log` |
| `/var/www/html` | WordPress: the capsule's volume, or the git capsule's repo |

---

## Tracks and tags

Tracks: `php8.3`, `php8.4` (default for new capsules), `php8.5`. Each track's `REVISION` moves on
its own (currently `php8.3-r5`, `php8.4-r6`, `php8.5-r5`).

Images go to `europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime`:

- `php<minor>-r<REVISION>` (e.g. `php8.4-r5`): **immutable**. This is what capsule-api deploys
  (`WORDPRESS_RUNTIME_TAGS`). `push.sh` refuses to overwrite an existing one.
- `php<minor>`: a moving alias for humans. **Never deploy the moving tag**: pods pull
  `IfNotPresent`, so a re-pushed tag never reaches running capsules.

To add a track: add `tracks/php<minor>.env` (`BASE_IMAGE=wordpress:php<minor>-fpm@sha256:…`,
`MIN_PHP_VERSION`, `REVISION=1`), add the minor to the `smoke` matrix in
`.github/workflows/runtime.yml`, check that Renovate's `matchStrings` still match it (they expect
`php8.<n>-fpm`), then add the tag to capsule-api's `WORDPRESS_RUNTIME_TAGS`.

## Releasing a runtime

1. Bump the track: `BASE_IMAGE` digest
   (`docker buildx imagetools inspect wordpress:php8.4-fpm --format '{{.Manifest.Digest}}'`)
   and `REVISION` in `tracks/php<minor>.env`. Raise `MIN_PHP_VERSION` when a security fix makes
   older PHP unacceptable. Any change to the image contents (nginx, scripts, runtime files) also
   needs a `REVISION` bump once the previous revision has been pushed.

   Renovate (`renovate.json`) checks the base-image digests before 6am (UTC) every Monday and
   opens a PR when one has moved (several tracks can arrive in one PR). It does not touch
   `REVISION`: **the PR author must bump `REVISION` for every changed track in the same PR**. The
   `runtime` workflow runs on every PR: it fails a `BASE_IMAGE` change without a `REVISION`
   change, runs the unit tests, and builds and smoke-tests every track (it never pushes). It
   cannot see a content change without a bump; `push.sh` refusing the existing tag is the
   backstop.
2. Build: `./build.sh 8.4`. It builds linux/amd64 with `--pull`, tags the immutable ref and the
   moving alias locally, and prints the immutable ref last; extra arguments go to
   `docker buildx build`.
3. Smoke: `tests/smoke.sh <ref> <MIN_PHP_VERSION>`. Every check must `PASS`.
4. Push: `./push.sh 8.4` (immutable tag, then the moving alias). It stops when the local image is
   missing or its PHP is older than the track's `MIN_PHP_VERSION`, when the tag already exists,
   and when the registry cannot be asked (log in again first: an expired login must not turn into
   an overwrite of a deployed tag).
5. Bump the tag in capsule-api's `WORDPRESS_RUNTIME_TAGS` and deploy it.
6. Run capsule-api's `redeploy-wordpress-capsules` job to roll the new tag to every capsule on
   that track.

### Build arguments

| Argument | Default | Description |
|---|---|---|
| `BASE_IMAGE` | none (required) | Set from the track by `build.sh` |
| `MIN_PHP_VERSION` | none (required) | Set from the track by `build.sh`; the build fails on an older PHP |
| `TARGETARCH` | `amd64` | `amd64` or `arm64`. `build.sh`, CI and the smoke test only build and test `amd64`. |
| `NGINX_EXPORTER_VERSION`, `NGINX_EXPORTER_SHA256_AMD64` / `_ARM64` | `1.5.3` | nginx-prometheus-exporter version and release checksums |
| `FPM_EXPORTER_VERSION`, `FPM_EXPORTER_SHA256_AMD64` / `_ARM64` | `2.2.0` | php-fpm_exporter version and release checksums |
| `WP_CLI_VERSION`, `WP_CLI_SHA512` | `2.12.0` | WP-CLI version and checksum |
| `PHPREDIS_VERSION` | `6.3.0` | PhpRedis PECL version |

The exporters and WP-CLI are pinned by version and checksum: bump each version together with its
published checksums. PhpRedis is pinned by PECL version only, and the build fails if the extension
does not load.

The image also installs nginx with the Debian `headers-more` and `cache-purge` modules, installs
the production `php.ini`, and closes ImageMagick's PostScript and Ghostscript coders (`PS`, `PS2`,
`PS3`, `EPS`, `XPS`, `MVG`, `MSL`) in its `policy.xml`. PDF thumbnails keep working.

## Local development and tests

Build a track, then run it on http://localhost:8000:

```bash
./build.sh 8.4
```

```bash
./docker_run.sh 8.4
```

`docker_run.sh` runs the local `php<minor>` image against a MySQL on the host
(`host.docker.internal:3306`, database `wordpress`, credentials in the script) with a `wordpress`
volume, `WORDPRESS_DEBUG=true` and `SESSION_COOKIE_SECURE=0`.

**Unit tests.** `tests/run.sh` runs every `tests/test_*.sh`: cgroup detection, the sizing model,
the configure scripts, the validators, the awk merge, the cron trigger's site selection, the
Cloudflare range check, the push guards (against a fake `docker`) and the platform prepend's
on/off switches (with the local `php` CLI; skipped when there is none). They need bash 4+ but no
Docker; on macOS use Homebrew's bash:

```bash
/opt/homebrew/bin/bash tests/run.sh
```

**Smoke test.** `tests/smoke.sh <image-ref> <MIN_PHP_VERSION>` starts the image against a
throwaway `mysql:8.4` container, installs WordPress with WP-CLI and prints `PASS`/`FAIL` per check:
PHP version and extensions, WP-CLI, the ImageMagick policy, the starting page, the prepend
constants, cache bypass and purge, `DONOTCACHEPAGE`, blocked files, XML-RPC, upload limits,
metrics, the sized limits and pinned overrides, the capacity cap, an upstream crash, env
fallbacks (including misspelt on/off switches and timeouts), cron on a multisite network and on an
HTTPS site, `/healthz`, graceful shutdown, an
existing volume, and the `git/` image. It exits 0 only when every check passes. It builds the
`git/` image on top of the image under test, so that image must be in the local image store (the
default `docker` buildx driver, not a `docker-container` builder).

---

## Container startup

`run.sh` is the entrypoint. It:

1. Creates `/var/run/wp-runtime` for state shared with PHP, with an empty cron heartbeat file in it.
2. Reads the container's cgroup CPU and memory limits and sizes PHP, PHP-FPM and nginx to them
   (logged as `[sizing]` lines; see [Resource-aware sizing](#resource-aware-sizing)).
3. Writes the sized PHP ini defaults merged with `$WORDPRESS_CUSTOM_INI` to `$PHP_INI_DIR/conf.d/zz-custom.ini`.
4. Writes the sized PHP-FPM pool config merged with `$WORDPRESS_FPM_CONF` to `/usr/local/etc/php-fpm.d/zzz-custom.conf`.
5. Generates the nginx config fragments from environment variables and the sizing (worker count,
   PHP capacity cap, rate limits, cache, headers, ...).
6. Validates the configuration with `nginx -t`. A broken `NGINX_EXTRA_CONF` is disabled (and
   logged) and the test runs again, instead of crash-looping the pod; any other failure exits 1.
7. Starts nginx with a "starting up" holding page: HTTP 503 with `Retry-After: 5` and
   `Cache-Control: no-store` on every path, `/healthz` included. The page reloads itself every 5 s.
8. Starts php-fpm through the upstream entrypoint. On a first boot it copies WordPress core onto
   the volume before FPM listens, which can take a minute on a network volume. The holding page is
   dropped the moment FPM listens on `127.0.0.1:9000` (or after `FPM_STARTUP_TIMEOUT_SECONDS`,
   with a log line). TCP probes therefore pass at once (no startup-probe kill during the copy)
   and HTTP probes stay honest. If php-fpm exits before it listens, the container exits with its
   status.
9. Starts the two Prometheus exporters (as `www-data`), then the internal wp-cron trigger.
10. Waits on nginx and php-fpm. If either exits, the container shuts down and exits non-zero (1 if
    it exited cleanly). The exporters and the cron trigger are not supervised: one that dies is not
    restarted and does not stop the container.

On `SIGTERM` (the image's stop signal), `SIGQUIT` or `SIGINT`, `run.sh` stops the cron trigger and
the exporters and sends nginx and php-fpm `SIGQUIT`: nginx finishes its in-flight requests, and
php-fpm gives each worker up to `process_control_timeout` (10 s, in the pool's `[global]`
defaults) to finish its request. `run.sh` waits up to `SHUTDOWN_TIMEOUT_SECONDS` for both, then
sends `TERM` and, a second later, `KILL` to anything still running, and exits 0.

| Variable | Default | Description |
|---|---|---|
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | Seconds a graceful shutdown waits for nginx and php-fpm before terminating them. |
| `FPM_STARTUP_TIMEOUT_SECONDS` | `600` | Seconds the holding page is served while waiting for php-fpm to listen on a slow first boot. After that the page is removed anyway and startup continues. |

Both take a whole number of seconds, at least 1. Anything else (`20s`, `10m`, `0`) falls back to
the default with a `[run] Invalid ...` line.

`run.sh`, the nginx master and the php-fpm master run as root. The nginx and PHP-FPM workers and
the exporters run as `www-data`, and the cron trigger calls WP-CLI as `www-data`.

`/healthz` is answered by PHP-FPM's ping path through an uncapped upstream. It fails (502) when
FPM is down and returns 503 while the holding page is up. When the pool is saturated it waits for
a worker rather than being shed, so give liveness probes a generous timeout.

nginx access and error logs and php-fpm's error log go to the container's stdout/stderr, i.e. the
platform log viewer. Nothing else is written to log files inside the container (the startup
`nginx -t` output is kept in `/var/run/wp-runtime/nginx-t.log` and copied to stderr when the test
fails). PHP-FPM's slow log is off: it needs `ptrace`, which the capsule's security context forbids;
nginx's access log carries `rt=` and `urt=` per request instead.

---

## Environment Variables

An invalid value for the numeric, size, CIDR, header and on/off variables below falls back to the
default, with an `Invalid ...` line in the container log (prefixed `[nginx-overrides]`,
`[custom-ini]`, `[sizing]` or `[run]`, by the script that reads it). A whole number with leading
zeros is read as decimal (`08` is 8). Values nginx itself would reject count as
invalid (an IPv4 prefix above `/32` or an IPv6 prefix above `/128`, a size above `100G`,
`RATE_LIMIT_MAX_CONN_PER_IP` above 65535, `NGINX_WORKER_PROCESSES` above 64), so a typo cannot
crash-loop the pod.

On/off switches take `true`/`false`, `1`/`0`, `yes`/`no` or `on`/`off`, in any case, with
surrounding spaces ignored. Anything else falls back to the switch's default:
`DISABLE_PUBLIC_WP_CRON=ture` keeps `wp-cron.php` restricted, and `WP_CRON_TRIGGER_ENABLED=enabled`
keeps the internal trigger running. A misspelt `WP_DISABLE_WP_CRON` is ignored, so
`DISABLE_WP_CRON` follows `WP_CRON_TRIGGER_ENABLED` as if it were unset. The platform prepend and
the metrics endpoint read some of these switches themselves, in every request and in a
`docker exec` shell, and apply the same rule. The `Invalid` line is logged once, at startup. It is
skipped for the prepend's switches when `WP_RUNTIME_PREPEND_ENABLED` is off. `SESSION_COOKIE_SECURE`
is the exception: it takes only `0` or `1`.

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
every request and every WP-CLI command. It marks the request as HTTPS when Traefik's
`X-Forwarded-Proto` says so, defines a few hardened defaults for constants the site has **not**
defined itself, writes the cron heartbeat, and loads the runtime mu-plugin. A constant defined in
`wp-config.php` or `WORDPRESS_CONFIG_EXTRA` always wins.

| Variable | Default | Constant / effect |
|---|---|---|
| `WP_RUNTIME_PREPEND_ENABLED` | `true` | `false` turns the whole prepend off: no HTTPS detection, no defaults (so WordPress's page-load cron spawner is back, and its self-request to the blocked `wp-cron.php` fails), no mu-plugin, and no cron heartbeat (`wp_cron_trigger_last_success_timestamp_seconds` stays 0). An `auto_prepend_file` in `WORDPRESS_CUSTOM_INI` replaces the prepend the same way. |
| `WP_DISABLE_WP_CRON` | follows `WP_CRON_TRIGGER_ENABLED` | `DISABLE_WP_CRON`: WordPress's page-load cron spawner is off because the runtime triggers cron internally |
| `WP_DISALLOW_FILE_EDIT` | `true` | `DISALLOW_FILE_EDIT`: the theme/plugin file editors are off (a compromised admin account would otherwise be code execution) |
| `WP_MEMORY_LIMIT` | the sized php.ini `memory_limit` (128M below 1.5 GiB, else 256M) | `WP_MEMORY_LIMIT`. WordPress raises `memory_limit` to this when it is higher, so it follows the container-sized cap instead of defeating it (WordPress's own default is 40M). A value above the sized limit is fed back into the sizing (fewer, bigger workers) like a `memory_limit` pin in `WORDPRESS_CUSTOM_INI`; `-1` is warned about, since the pool cannot account for it |
| `WP_MAX_MEMORY_LIMIT` | sized: twice the request limit where the container can hold it (128M on Basic, 256M on Standard and Premium, 512M from 1.5 GiB) | `WP_MAX_MEMORY_LIMIT` (admin screens, image editing, upgrades, cron). The runtime mu-plugin also applies it to an administrator's admin-ajax, admin-post and REST requests, which core leaves at the front-end limit |
| `WP_REDIS_HOST` (+ `WP_REDIS_PORT`, `WP_REDIS_PASSWORD`, `WP_REDIS_DATABASE`, `WP_REDIS_PREFIX`) | unset | When set, the Redis Cache plugin's constants are defined from these (see [Redis Object Cache](#redis-object-cache)) |
| `WP_RUNTIME_MU_PLUGIN_ENABLED` | `true` | Loads the runtime mu-plugin: page-cache purge on content changes, the `DONOTCACHEPAGE` relay, the admin memory raise, "Purge page cache" in the admin bar, `wp cc cache purge` / `wp cc cache status` |

The prepend finds the site's own constants by reading text: a `define('NAME', ...)` in
`WORDPRESS_CONFIG_EXTRA`, in the docroot's `wp-config.php`, or in a `wp-config.php` one directory
up. A constant defined in a file that `wp-config.php` includes, or with `const`, is not seen: the
prepend defines its default first and the site's own `define()` is ignored with a warning. Put
overrides in `wp-config.php` itself. A commented-out `define()` still counts and switches the
default off.

#### `WORDPRESS_CONFIG_EXTRA`

Arbitrary PHP that the `wp-config.php` generated by the upstream WordPress Docker entrypoint (from
`wp-config-docker.php`) `eval()`s on every request, so changes apply on redeploy. A `wp-config.php`
the entrypoint did not generate (one you supplied, or a git capsule's) ignores it: define the
constants there instead. Use this for WordPress constants:

```
WORDPRESS_CONFIG_EXTRA=define('FORCE_SSL_ADMIN', true);
define('WP_AUTO_UPDATE_CORE', 'minor');
```

#### `WORDPRESS_CUSTOM_INI`

Custom PHP ini settings merged **over** the sized defaults (a key you set replaces the default;
keys you don't set keep their sized value; unknown keys are appended). The defaults already
include a production php.ini, OPcache sized to the container (`validate_timestamps=1` /
`revalidate_freq=60` so plugin updates are picked up), a container-sized `memory_limit`,
`max_input_vars = 3000`, a large realpath cache, `expose_php = Off`, errors to stderr (never to the
page), and `HttpOnly` / `SameSite=Lax` session cookies. Nothing needs to be set for a capsule to be
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
> `WP_MEMORY_LIMIT` / `WP_MAX_MEMORY_LIMIT` defaults follow it too. A `WP_MEMORY_LIMIT` environment
> variable above the limit is fed back the same way, since WordPress raises `memory_limit` to it on
> every request. A `memory_limit` of `-1`, below 2M or unparseable is applied by PHP but ignored by
> the sizing (logged).

> **Note:** the defaults set `auto_prepend_file` to the platform prepend. An `auto_prepend_file`
> here replaces it, and with it everything in [Platform defaults](#platform-defaults-the-prepend).

#### `WORDPRESS_FPM_CONF`

Custom PHP-FPM pool configuration, merged over the sized defaults the same way (per `[section]`).
Only needed to pin a pool by hand. A `pm.max_children` set here re-derives `pm.start_servers` /
`pm.min_spare_servers` / `pm.max_spare_servers` and the nginx capacity cap from the pinned value
(PHP-FPM refuses to start when `max_spare_servers` exceeds `max_children`), unless you set those
too:

```ini
[www]
pm = static
pm.max_children = 16
request_terminate_timeout = 60s
```

Besides the sized pool, the defaults are `pm = dynamic`, `pm.max_requests = 500` (workers are
recycled), `request_terminate_timeout = 300s`, `listen.backlog = 2048` and, under `[global]`,
`process_control_timeout = 10s`. php-fpm's own access log is off (nginx logs every request with the
real client IP, timing and cache status); PHP errors still go to the container's stderr. PHP-FPM
listens on `127.0.0.1:9000` only.

Timeouts are wall-clock: `request_terminate_timeout = 300s` in the pool (what WordPress budgets for
core and plugin upgrades, which a 0.07–0.25 vCPU pod needs), nginx `fastcgi_read_timeout` 300s for
`/wp-admin/*.php` and 120s for public requests. php.ini's `max_execution_time = 60` counts CPU time
on this build and never fires at a fraction of a vCPU. When nginx gives up on a public request at
120s it closes the FastCGI connection, which frees that request's slot under the capacity cap, but
the PHP-FPM worker keeps running the script until it next writes output or
`request_terminate_timeout` fires, so a burst of abandoned slow requests can keep workers busy for
up to 180s after their clients saw a 504.

> **`clear_env = no`** is set so WordPress can read `WORDPRESS_DB_HOST` etc. via `getenv()`, which
> means **all** environment variables are visible to PHP code. Do not inject secrets as env vars
> that WordPress plugins should not access.

---

### Resource-aware sizing

Kubernetes enforces a capsule's scale with cgroup limits, but nothing inside the container reports
them: `nproc` and `/proc/meminfo` describe the *node*. The image therefore reads its own cgroup
(v2 or v1) at startup and derives the PHP, PHP-FPM and nginx defaults from the real limits, so one
image is safe on the 0.28 GB Basic plan and uses all of a multi-GB custom one. The sizing is logged
on every boot (here the 1 GB Premium plan):

```
[sizing] Container limits (cgroup): memory=953M cpu=250m
[sizing]   php: memory_limit=128M wp_max_memory_limit=256M opcache=160M interned_strings=16M imagick: memory=128MiB map=256MiB
[sizing]   php-fpm: max_children=3 (memory-bound=10, cpu-bound=3, worker_budget=64M, reserved=139M) start=1 spare=1-2
[sizing]   nginx: worker_processes=1 max_inflight_php_requests=12
```

When the pool floor is applied a `WARNING:` or `note:` line follows, and `(cgroup)` reads `(host)`
when the container has no limit.

The model (`scripts/lib/resource_sizing.sh`), all in MiB:

| Setting | Rule | Why |
|---|---|---|
| `memory_limit` | 128M below 1.5 GiB, 256M from 1.5 GiB | Per-request cap. Front-end requests peak at 40–70 MB even on heavy sites (measured under load on a 15-plugin multilingual site); admin work gets `WP_MAX_MEMORY_LIMIT` (below). |
| `opcache.memory_consumption` | memory ÷ 6, clamped 96–256, rounded to 16 | Shared segment, charged to the container only as pages are touched, so erring large costs nothing; a full OPcache recompiles files on every request, which a 0.07-CPU pod cannot afford. Core + a typical plugin set compiles to 40–120 MB. |
| `opcache.interned_strings_buffer` | 32 from an OPcache of 192M, 16 from 128M, else 8 | |
| reserved | 80 + memory ÷ 16 | nginx, the two exporters, the FPM master, and page-cache headroom (the pod idles at ~70–80 MB). |
| worker budget | `memory_limit` ÷ 2 (`PHP_WORKER_MEMORY_MB`) | Private memory budgeted per FPM worker. Measured 28–48 MB average / 60 MB peak per worker under load; 35–50 MB for a fresh install on this platform. |
| `pm.max_children` | min( (memory − reserved − opcache) ÷ worker budget, ceil(CPU × `PHP_FPM_WORKERS_PER_CPU`) ), clamped 3–64 | The memory bound keeps the pool inside the container; the CPU bound stops forking workers the quota cannot run (they only add memory and contention). The floor of 3 is from the Basic plan: with 2 workers, two slow requests stalled the site, and the internal cron trigger takes a worker every minute. |
| `pm.start_servers` / spare | start ⌈⅓⌉, spare ⌊¼⌋ (at least 1) – ⌈½⌉ of `max_children` | Kept in PHP-FPM's order: min spare ≤ start ≤ max spare ≤ `max_children`. |
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
| Custom | 2 GB | 1 | 256M | 512M | 256M | 11 | 44 | 1 |
| Custom | 4 GB | 2 | 256M | 512M | 256M | 24 | 96 | 2 |
| Custom | 8 GB | 4 | 256M | 512M | 256M | 48 | 192 | 4 |

Memory is the limit the cgroup reports, in decimal GB (1 GB = 953 MiB, as in the boot log above).
A 2 GB custom capsule is just under the memory bound for 12 workers; at 2000 MiB or more it gets 12
workers and a cap of 48.

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
| `MAGICK_MEMORY_LIMIT` / `MAGICK_MAP_LIMIT` | from the sizing (e.g. `128MiB` / `256MiB`) | ImageMagick resource limits, in ImageMagick's syntax. Each one overrides only itself. |
| `NGINX_WORKER_PROCESSES` | ceil(CPU), 1–4 | nginx worker count (1–64). |

The limits are read from `memory.max` / `cpu.max` (cgroup v2) or `memory.limit_in_bytes` /
`cpu.cfs_quota_us` (v1); a memory limit above 1 TiB counts as none. Without a cgroup limit (local
`docker run` without `--memory`/`--cpus`) the sizing falls back to the host's memory and CPU count
and says so in the log. The sizing is also exported as `cc_runtime_*` gauges on the internal
metrics endpoint.

---

### Upload Size

#### `MAX_UPLOAD_SIZE`

Controls `client_max_body_size` in nginx **and** `upload_max_filesize` / `post_max_size` in PHP,
keeping them in sync. Default `64M`. Accepts a whole number with a `K`, `M` or `G` suffix (case
does not matter), from `1024K` to `100G` (`64M`, `256M`, `1G`). Anything else (`64MB`, `0`, a bare
byte count, `064M`) is rejected with a log line and the default is used.

---

### Caching

The nginx FastCGI full-page cache is **on by default** for anonymous `GET`/`HEAD` requests, with a
60-second TTL.

- **Stored:** 200s and canonical 301s for `CACHE_TTL_SECONDS`, and anonymous 404s for a fixed
  minute. Nothing else, never a 302 (geolocation and language redirects are per visitor).
- **Bypassed** (never served from the cache nor stored):
  - logged-in users, commenters, password-protected posts and carts: the cookies
    `wordpress_logged_in`, `wordpress_sec`, `wp-postpass`, `comment_author`,
    `woocommerce_items_in_cart`, `woocommerce_cart_hash`, `wp_woocommerce_session`,
    `edd_items_in_cart`;
  - `/wp-admin`, `/wp-login.php`, `/wp-cron.php`, `/xmlrpc.php`, the REST API (`/wp-json`,
    `/index.php/wp-json`, `?rest_route=`), `/wc-api`, and `/cart`, `/checkout`, `/my-account`,
    `/account` at the site root;
  - previews and builders (`preview=true`, `customize_changeset_uuid`, `elementor-preview`),
    `wc-ajax`, `add-to-cart`, and search (`s`);
  - `POST`, `PUT`, `PATCH` and `DELETE`.
- **Not stored:** a response that sets a cookie, one carrying WordPress's own no-cache headers
  (`nocache_headers()`, or `no-store` / `private`; 404s excepted), an empty body
  (`CACHE_SKIP_EMPTY`), and any page WordPress declares uncacheable with `DONOTCACHEPAGE`
  (WooCommerce, membership and login plugins define it; a cart or checkout page under another slug
  relies on it). The runtime mu-plugin relays `DONOTCACHEPAGE` to nginx when the response is
  produced, from `template_redirect` on, so a plugin that defines it and exits there is covered
  too. One that exits earlier (on `init` or `parse_request`) is not seen.
- **Stale pages:** an expired page is served stale while one request refreshes it in the background
  (stale-while-revalidate), and also when PHP errors, times out or answers 500/503 (maintenance
  mode, a fatal error, the capacity cap). A cache lock makes concurrent misses for one page wait
  up to 10 s for the first render. Entries nobody requested for 60 minutes are evicted whatever
  the TTL.
- **Purge:** the runtime mu-plugin purges the whole cache, at most once per request (at shutdown),
  when content changes (posts, pages, comments, terms, menus, widgets, the customizer, theme
  switches, plugin (de)activation, upgrades, relevant options), from the "Purge page cache"
  admin-bar item (administrators, while the cache is on), and via `wp cc cache purge`. Themes and
  plugins can `do_action('cc_cache_purge')`; `cc_cache_purged` fires after each purge with the
  result and the reason, and a failed purge logs `[cc-runtime] page cache purge failed`.

The cache and its purge are per container: with more than one replica, a purge clears only the
replica that ran it, and the others serve their copy until the TTL runs out.

| Variable | Default | Description |
|---|---|---|
| `CACHE_TTL_SECONDS` | `60` | Cache TTL. `0`, `off`, `false`, `no`, `none` or `disabled` turns the page cache off. |
| `CACHE_MAX_SIZE` | `512M` | Upper bound of the on-disk cache (`<n>K` from 1024K, `<n>M` or `<n>G` up to 100G). |
| `CACHE_IGNORE_QUERY_PARAMS` | unset | JSON array of query-parameter name patterns to ignore in the cache key, e.g. `'["utm_*","fbclid"]'` (`*` matches any characters within a name; matching is case-sensitive; allowed: `A–Z a–z 0–9 _ * -`). Ignored while the cache is off. |
| `CACHE_SKIP_EMPTY` | `true` | Never store a response whose upstream `Content-Length` is `0` (a blank page from a failed output buffer). A response without `Content-Length` cannot be judged and is cached normally. |
| `DEBUG_HEADERS` | `false` | `true` adds `X-Cache: HIT\|MISS\|BYPASS\|EXPIRED\|STALE\|UPDATING\|...` to responses of the caching PHP handler (front end and REST; not wp-admin, wp-login.php, comments, XML-RPC or wp-cron). |

> **Which TTL should I use?**
>
> - The default `60` is right for most sites: visitors see changes within a minute even if a
>   purge is missed, and busy pages are rendered at most once a minute.
> - Raise it (`600`, `3600`) for mostly static sites; the purge-on-publish keeps content fresh.
>   Pages requested less than hourly are evicted anyway, so a TTL above `3600` only helps pages
>   that stay busy.
> - Set `CACHE_TTL_SECONDS=0` for real-time dashboards, membership/LMS sites with
>   per-visitor content that does not set cookies, or when a WordPress cache plugin manages page caching.

Cache key normalisation example with `CACHE_IGNORE_QUERY_PARAMS='["utm_*"]'`:

| Request | Cache behavior |
|---|---|
| `GET /page/1?utm_term=xyz` | MISS — rendered and stored |
| `GET /page/1?utm_term=abc` | HIT — same cache entry as above |
| `GET /page/1` | HIT — same cache entry |
| `GET /page/1?page=2&utm_term=xyz` | Key includes `page=2` only (utm params stripped from key) |

Up to 16 matching parameters are stripped per URL. The cache key is
`<scheme>|<method>|<host>|<request_uri>` (with ignored parameters, the path plus the remaining
arguments). The purge endpoint (`/.cc-cache-purge`, loopback only, token protected) accepts an
exact key, a `<prefix>*` or `*`.

---

### Rate Limiting

| Variable | Default | Description |
|---|---|---|
| `RATE_LIMIT_NORMAL_ROUTES_RPM` | `300` | Req/min per IP for public routes (burst 100) |
| `RATE_LIMIT_PROTECTED_ROUTES_RPM` | `120` | Req/min per IP for `/wp-admin/`: PHP files incl. `admin-ajax.php`, and non-asset paths (burst 60) |
| `RATE_LIMIT_LOGIN_ROUTES_RPM` | `30` | Req/min per IP for `wp-login.php` (burst 10), `wp-comments-post.php` (burst 5), `xmlrpc.php` (burst 3), and a public `wp-cron.php` (`DISABLE_PUBLIC_WP_CRON=false`, burst 3) |
| `RATE_LIMIT_API_ROUTES_RPM` | `300` | Req/min per IP for `/wp-json/` (burst 100; the block editor makes many REST calls) |
| `RATE_LIMIT_MAX_CONN_PER_IP` | `100` | Max concurrent connections per IP |

Static assets are never request-rate-limited, but the per-IP connection limit applies to every
request. Both limits answer `429`. All limits are **per client IP**, resolved from
`X-Forwarded-For` (see below). If the true client IP is not resolved correctly, every visitor
shares one bucket and trips these limits with spurious `429`s; the `limiting requests` log lines
are in the container logs.

In addition to these per-IP limits, PHP has a capsule-wide capacity cap sized to the PHP-FPM pool
(see [Resource-aware sizing](#resource-aware-sizing)). Requests past it get `503` with
`Retry-After: 5` and a holding page that reloads itself every 5 s (`no live upstreams` in the error
log), while cached pages and static files keep being served. A PHP worker that crashes or is killed
mid-request (`request_terminate_timeout`, an OOM kill) is a plain `502`, not the holding page: only
the cap, where nginx never selected a server, gets it.

---

### Real Client IP & Cloudflare

nginx resolves the real client IP from `X-Forwarded-For` (`real_ip_recursive on`) and uses it for
all rate limits, the per-IP connection limit, access logs, and the IP passed to WordPress
(`REMOTE_ADDR` / `X-Real-IP`). Trusted hops:

| Variable | Default | Description |
|---|---|---|
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` | Intermediaries whose `X-Forwarded-For` is believed (Traefik / k8s LB / VPC). IPv4 or IPv6, space- or comma-separated; narrow it to the Traefik pod CIDR where possible. One invalid entry replaces the whole list with the default. |

plus **Cloudflare's published edge ranges**, baked into the image at build time from
`cloudflare.com/ips-v4` and `ips-v6` (falling back to `cloudflare_ips.fallback.conf` with a
warning if either fetch fails or returns anything but CIDRs). Rebuild the image to refresh them.
They are trusted on every capsule, whether or not it sits behind Cloudflare; there is no runtime
switch.

> ⚠️ **Security:** Trusting Cloudflare's *public* ranges means a client that can reach the origin
> **directly** (bypassing Cloudflare) could forge `X-Forwarded-For`. Lock the origin to Cloudflare
> only: edge IP allowlist at your load balancer, Authenticated Origin Pulls, or a Cloudflare Tunnel.
> Traefik itself must forward `X-Forwarded-For` from Cloudflare (`forwardedHeaders.trustedIPs`).
> Check the access log on a test capsule: the first field is the resolved client IP and should be
> the visitor, `xff=` is the raw header, and `realip=` is the hop that connected to nginx (Traefik).

---

### Security & Behaviour

| Variable | Default | Description |
|---|---|---|
| `XMLRPC_ENABLED` | `false` | `true` enables XML-RPC (Jetpack, WP mobile app, external publishing); still rate-limited. Off, `/xmlrpc.php` answers `403`. |
| `SESSION_COOKIE_SECURE` | `1` | PHP `session.cookie_secure`: `0` (for local HTTP development) or `1`; anything else is logged and gives `1`. |
| `CSP_HEADER` | see below | Full `Content-Security-Policy` value, on one line. Empty string disables it. Only letters, digits, spaces and `' * : ; / . , _ = + ~ ! % @ -` are allowed: any other character (quotes, `$`, `\`, `?`, `&`, `#`, brackets) rejects the value and the default is used, so a `report-uri` with a query string does not work. |
| `HSTS_HEADER` | `max-age=31536000` | `Strict-Transport-Security` value, sent only on HTTPS requests. Empty string disables it. Same character rules as `CSP_HEADER`. Add `; includeSubDomains` yourself only if every subdomain of the domain is HTTPS. |

Default CSP:
```
default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: https:; connect-src 'self' https: wss:; frame-ancestors 'self';
```

Always sent, not configurable through env: `X-Content-Type-Options: nosniff`,
`X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`,
`Permissions-Policy: geolocation=(), microphone=(), camera=()` (so those browser APIs are off for
the site itself) and `X-Permitted-Cross-Domain-Policies: none`.

Security headers are set with the headers-more module, so they are present on every response
(static assets and `NGINX_EXTRA_CONF` locations included) and replace a header of the same name
sent by WordPress or a plugin (a security plugin's own CSP is overwritten by `CSP_HEADER`).

---

### Cron

| Variable | Default | Description |
|---|---|---|
| `DISABLE_PUBLIC_WP_CRON` | `true` | Restrict `wp-cron.php` to `127.0.0.1`; the runtime triggers it internally. `false` makes it public, under the login rate limit (burst 3). |
| `WP_CRON_TRIGGER_ENABLED` | `true` | `run.sh` calls each site's `wp-cron.php` through the container's nginx on an interval. Set to `false` only if the capsule triggers cron some other way (see below). |
| `WP_CRON_TRIGGER_INTERVAL_SECONDS` | `60` | Seconds between internal `wp-cron.php` triggers. |
| `WP_CRON_TRIGGER_SITES_PER_RUN` | `3` | Sites triggered per run. A multisite network with more sites is covered in rotation, in site-id order: each site every ceil(sites ÷ this) runs, logged at startup and whenever the site list changes, with a warning when that is longer than an hour. A large network cannot tie up the whole PHP-FPM pool every minute; raise this (or shorten the interval) when the warning appears. |
| `WP_CRON_TRIGGER_TARGETS_REFRESH_SECONDS` | `3600` | How long the list of site URLs (asked from WordPress with WP-CLI, as `www-data`, without plugins or themes) is kept. |

**How cron is triggered.** `wp-cron.php` answers before WordPress loads (it calls
`fastcgi_finish_request()` first), so the trigger's HTTP status cannot say whether cron ran. The
trigger therefore requests each site the way its visitors reach it: the host, path and scheme of the
site URL that WordPress reports (`X-Forwarded-Proto: https` for an HTTPS site, so a plugin that
redirects plain-HTTP requests does not end the cron request early), and every live site of a
multisite network (all of them, not archived, deleted or spam; `WP_CRON_TRIGGER_SITES_PER_RUN` per
run, in rotation) rather than an address WordPress cannot route. A site URL that is not a plain
`http(s)://host[:port]/path` is skipped. Until WordPress can answer (not installed yet, database
down) it triggers `http://127.0.0.1/` and asks again within five minutes.

The heartbeat (`wp_cron_trigger_last_success_timestamp_seconds`) is written by PHP when the cron
dispatcher of a `wp-cron.php` request reaches its event list, not by the trigger, so it only
advances when cron really ran. It is per container (any site of a network advances it) and resets
to 0 at every container start until the first run.

With `WP_CRON_TRIGGER_ENABLED=false`, the prepend defines `DISABLE_WP_CRON` as `false` and
WordPress's page-load spawner is back on. Its self-request, like any external cron service, reaches
`wp-cron.php` from outside the container and is refused unless `DISABLE_PUBLIC_WP_CRON=false`.

---

### Nginx Customisation

#### `NGINX_EXTRA_CONF`

Raw nginx config injected into the `server {}` block after the built-in locations, just before the
PHP handler. Useful for custom proxy rules, headless WordPress API routes, WooCommerce custom
endpoints.

```
NGINX_EXTRA_CONF=location /custom-api/ { proxy_pass http://internal-service:8080/; }
```

A regex location in the fragment is checked after the built-in blocking and static-asset regexes,
and redefining a built-in location (`/`, `/wp-admin/`, `= /wp-login.php`, `^~ /wp-json/`, ...) is
an error. The fragment's locations get the security headers and the per-IP connection limit, but
no request rate limit unless they add `limit_req`.

If the fragment does not pass `nginx -t`, the container logs the error, disables the fragment and
starts without it, so a typo cannot take the site down.

---

## WP-CLI

`wp` is installed in the image. From a shell in the container, run it as the web server user so
the files it writes stay writable by WordPress:

```bash
setpriv --reuid=www-data --regid=www-data --clear-groups env HOME=/tmp wp --path=/var/www/html plugin list
```

`wp --allow-root --path=/var/www/html ...` is fine for read-only commands, but as root, installs and
updates (`wp plugin install`, `wp core update`, `wp redis enable`, ...) leave root-owned files on
the volume that WordPress cannot update later: updates then fail or WordPress asks for FTP
credentials. Besides the usual commands (`wp core version`, `wp plugin list`,
`wp search-replace`, `wp cron event run --due-now`), the runtime adds:

- `wp cc cache status` — whether the page cache is on, and its TTL (`enabled (TTL 60s)` or `disabled`)
- `wp cc cache purge` — purge the page cache

The platform prepend applies to the CLI too, so `wp` sees the same constants as the site, with two
exceptions: there is no HTTPS detection, and in an exec shell (which lacks the sizing environment
`run.sh` exports) `WP_MAX_MEMORY_LIMIT` is twice `memory_limit`, at least 256M.

---

## Prometheus Metrics

The container exposes three Prometheus metrics ports (the exporters run as `www-data`). No sidecar required.

| Port | Exporter | Key metrics |
|---|---|---|
| `9113` | nginx-prometheus-exporter | `nginx_connections_active`, `nginx_connections_waiting`, `nginx_http_requests_total` |
| `9253` | php-fpm_exporter | `phpfpm_listen_queue`, `phpfpm_max_children_reached`, `phpfpm_active_processes`, `phpfpm_idle_processes`, `phpfpm_total_processes` |
| `9254` | WordPress (`/metrics`) | `wp_cron_trigger_*`, `cc_runtime_*`, `wordpress_*` (below) |

The exporters read nginx's `stub_status` at `127.0.0.1:8080/nginx_status` and the pool status at
`127.0.0.1:9000/fpm-status`. They start once php-fpm listens, so `9113` and `9253` refuse
connections during a first boot. `phpfpm_slow_requests` is always 0: the slow log is off.

The WordPress application metrics on `9254` (path `/metrics`; every other path is a 404):

- `wordpress_published_posts_total`, `wordpress_published_pages_total`,
  `wordpress_approved_comments_total`, `wordpress_users_total`,
  `wordpress_autoloaded_options_total`, `wordpress_autoloaded_options_bytes`
- `wordpress_core_version_info{version, php_version}` (always 1)
- `wp_cron_trigger_enabled` and `wp_cron_trigger_last_success_timestamp_seconds` (alert on
  staleness only where the trigger is enabled)
- the sizing in effect: `cc_runtime_container_memory_bytes`, `cc_runtime_container_cpu_millicores`,
  `cc_runtime_fpm_max_children`, `cc_runtime_php_max_inflight_requests`,
  `cc_runtime_php_memory_limit_bytes`

Each scrape runs a few `COUNT(*)` queries in a PHP-FPM worker, outside the capacity cap; a 30–60 s
scrape interval is plenty. Port `9254` is unauthenticated, like the exporters: anything on the pod
network can scrape it. The same output is at `http://127.0.0.1:8080/wp-metrics` inside the
container. The script lives at `/usr/share/wp-runtime/wp-metrics.php`, outside the docroot, so a
volume over `/var/www/html` does not hide it.

> The cluster's Prometheus must be told to scrape these ports (a PodMonitor on the WordPress pod
> labels); nothing scrapes them by default.

**Recommended Prometheus alerts:**

```yaml
- alert: FPMWorkersExhausted
  expr: phpfpm_listen_queue > 0
  for: 1m

- alert: FPMMaxChildrenHit
  expr: increase(phpfpm_max_children_reached[5m]) > 0

- alert: FPMNoIdleWorkers
  expr: phpfpm_idle_processes == 0
  for: 2m

- alert: WordPressCronStale
  expr: wp_cron_trigger_enabled == 1 and time() - wp_cron_trigger_last_success_timestamp_seconds > 900
  for: 10m

- alert: WordPressAutoloadBloat
  expr: wordpress_autoloaded_options_bytes > 5e6
```

---

## Redis Object Cache

The **PhpRedis** C extension is baked into this image. To use Redis for object caching:

1. Create a Redis capsule and set `WP_REDIS_HOST` (and `WP_REDIS_PASSWORD` if needed) on the
   WordPress capsule. The prepend then defines `WP_REDIS_HOST`, `WP_REDIS_PORT` (6379),
   `WP_REDIS_PASSWORD` / `WP_REDIS_DATABASE` (only when set), `WP_REDIS_PREFIX`,
   `WP_REDIS_CLIENT=phpredis` and 1-second timeouts. Nothing is defined while `WP_REDIS_HOST` is
   unset.
2. Install and activate the [Redis Cache](https://wordpress.org/plugins/redis-cache/) plugin and
   click *Enable Object Cache* (or `wp redis enable`, as `www-data`: see [WP-CLI](#wp-cli)).

`WP_REDIS_PREFIX` defaults to `WORDPRESS_DB_NAME`, so sites sharing one Redis do not collide. When
`WORDPRESS_DB_NAME` is unset (a `wp-config.php` that carries the database name itself, as git
capsules often do) it falls back to `wordpress`: set `WP_REDIS_PREFIX` explicitly whenever several
such sites share one Redis.

Override any constant in `wp-config.php` or `WORDPRESS_CONFIG_EXTRA` (for example
`WP_REDIS_SCHEME` for TLS); the prepend never redefines a constant the site defines itself.

> **Fail fast:** keep `WP_REDIS_TIMEOUT`/`WP_REDIS_READ_TIMEOUT` low (1s). Redis sits on the
> critical path of every request, so a slow/unreachable Redis should error quickly rather than hang
> PHP-FPM workers.

---

## Email

The image ships no mail transport, so `wp_mail()` (password resets, WooCommerce order mails, form
notifications) does not deliver until the site has an SMTP plugin configured with a mail provider.
A platform relay driven by `SMTP_*` variables is on the roadmap.

---

## Optimisations Included

- **Full-page cache** on by default with purge-on-publish, stale-while-revalidate (and stale on errors), WooCommerce-aware bypass rules and `DONOTCACHEPAGE` honoured
- **Resource-aware sizing**: PHP `memory_limit`, OPcache, the PHP-FPM worker pool and nginx workers are derived from the container's real cgroup limits, so the container cannot over-commit its memory and be OOM-killed under load; production `php.ini`
- **Load shedding**: a capsule-wide cap on PHP-FPM connections sized to the pool answers `503` + `Retry-After` past capacity instead of queueing a burst for minutes, while cached pages and static files keep flowing; ImageMagick bounded to the sizing so a huge upload cannot OOM-kill the pod
- **Gzip compression**: reduces response sizes by 60–80%
- **Static file caching**: 30-day immutable browser cache for assets (CSS, JS, images, fonts, media, PDF, ZIP, wasm); 1h for existing XML/txt files
- **Security headers** on every response: HSTS (HTTPS only), CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, X-Permitted-Cross-Domain-Policies
- **Hardened WordPress defaults**: file editors off, sane memory limits, cron run by the platform
- **PHP execution blocked** in uploads, cache, and upgrade directories; drop-ins (`wp-content/*.php`) and `wp-includes/*.php` not requestable
- **Sensitive files blocked** (404): `wp-config.*`, `wp-config-sample.php`, `readme.html`, `license.txt`, `composer.*`, `package*.json`, `yarn.lock`, `.env`, `.git`, `.svn`, `.htaccess` / `.htpasswd` / `.user.ini`, every dotfile except `/.well-known/`, plugin and theme readme/changelog/license files, and the extensions `.sql`, `.sql.gz`, `.sql.zip`, `.bak`, `.old`, `.orig`, `.save`, `.swp`, `.swo`, `.ini`, `.log`, `.sh`, `.conf`, `.dist` (so a site cannot offer downloads with those extensions)
- **ImageMagick hardened**: the PostScript and Ghostscript coders are disabled
- **Rate limiting**: four configurable zones (public, wp-admin, login/comments/xmlrpc, REST) plus a per-IP connection limit, keyed on the real client IP behind Traefik/Cloudflare
- **Cloudflare-aware real IP**: edge ranges baked at build so XFF recursion resolves the true visitor IP
- **Graceful deploys**: a 503 holding page while PHP-FPM starts (no 502s; TCP probes pass at once, so a slow first boot is not killed); shutdown finishes in-flight requests
- **Logs in the platform**: nginx and PHP logs on stdout/stderr
- **Prometheus metrics**: in-container nginx and PHP-FPM exporters plus WordPress metrics
- **WP-CLI** in the image

---

## Git capsule image

`git/` layers a capsule's WordPress repo onto an immutable runtime tag
(`--build-arg RUNTIME_IMAGE=<ref>`, no default) and copies it to `/var/www/html` as `www-data`.
Everything else (nginx, PHP-FPM, sizing, metrics, cron trigger, env vars) comes from the runtime.
The Tekton build contract is in [`git/README.md`](git/README.md).

## Legacy images

`legacy/v_<wp>/` holds one image per WordPress version for capsules not yet moved to the runtime:
6.5–6.8 on PHP 8.3 (`wordpress:php8.3-fpm`), 6.9 on PHP 8.4 (`wordpress:php8.4-fpm`). Each bundles
a fixed WordPress core and predates the runtime: no sizing, prepend, mu-plugin, cache purge, WP-CLI
or cron trigger; only 6.9 has the configure scripts, the exporters and the Cloudflare ranges.
Build and push with `legacy/docker_build.sh <wp>` and `legacy/docker_push.sh <wp>` (the
`v_<wp>/docker_*.sh` wrappers call them). They produce
`europe-west4-docker.pkg.dev/appstrax/main/wordpress:<wp>` and the immutable
`wordpress:<wp>-php<php-version>` tag that capsule-api deploys; `docker_push.sh` uses the same
registry guard as `push.sh`.
