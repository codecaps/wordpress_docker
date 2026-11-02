# Runtime defaults: sizing port from `wordpress_git_docker` and review (2026-11-02)

Scope: `wordpress_docker` (`feat/wordpress-runtime`, the runtime behind every PHP track and the
git layer; the `legacy/` images are frozen snapshots awaiting deletion and were left alone).
Input: the resource-aware sizing in `wordpress_git_docker` `fix/performance` (commits
`e1b5b3d`..`f361260`, load-tested with k6 on cc-proxmox and in a local lab, written up in its
`docs/sizing-load-test-2026-10-27.md`). Method: both runtimes read in full, every default
compared, the sibling's model ported with this platform's measurements kept where they differ,
one concurrency experiment on the shipped `php8.4-r3` image, a shell test suite, the smoke test
on the rebuilt image, and a three-lens review panel whose findings were verified by hand.

## 1. Defaults compared and what r4 ships

| Setting | `wordpress_git_docker` | this repo before (r3) | r4 | Why |
|---|---|---|---|---|
| php `memory_limit` | 128M < 1.5 GiB, else 256M | 256M fixed | **sibling** | Front-end peaks measured at 40–70 MB under load; 128M produced no "Allowed memory size" errors. Admin gets `WP_MAX_MEMORY_LIMIT`. |
| `WP_MEMORY_LIMIT` / `WP_MAX_MEMORY_LIMIT` | WordPress defaults (40M / 256M) | prepend: 256M / 512M | **sized limit / 2× (≥ 256M)** | WordPress raises `memory_limit` to `WP_MEMORY_LIMIT` whenever it is higher, so r3's 256M constant would have silently undone a 128M ini cap. |
| `opcache.memory_consumption` | clamp(mem/8, 64, 256) | 96 / 128 / 256 tiers | **clamp(mem/6, 96, 256)** | Charged only as pages are touched, so erring large is free; a full OPcache recompiles on every request, which a 0.07-CPU pod cannot afford. WooCommerce + a page builder exceed 120 MB compiled. |
| `opcache.interned_strings_buffer` | 8 / 16 / 32 | 16 | **sibling** | Scales with the segment. |
| reserved (non-PHP) | 80 + mem/16 | 96 + opcache/4 | **sibling** | Measured ~70–80 MB idle on both platforms. |
| worker budget | `memory_limit`/2 (64M / 128M) | 56M | **sibling** | Measured 28–48 MB average / 60 MB peak per worker under load. |
| CPU bound | ceil(millicores × 12 / 1000) | ceil(CPUs) × 12 | **sibling** | r3 rounded 0.07 CPU up to one core: Premium (1G / 0.25 CPU) got 12 workers for a quarter of a core, the over-commit the sibling's load test showed holds memory for no throughput. r4: 3. |
| worker floor | 2 | 3 | **3** | r3's own measurement on the Basic plan (two slow requests stalled a 2-worker site) and the internal cron trigger occupying a worker every minute. Boot log warns when the floor exceeds the budget (Basic, Standard). |
| spares | ⅓ start, ¼–½ spare | ¼ start, ¼–½ | **sibling** | `max_spare` 2 instead of 1 on a 3-worker pool. |
| pinned overrides | `memory_limit` → budget, `pm.max_children` → spares | ignored by the sizing | **sibling** | A pinned `pm.max_children` below the sized spares made PHP-FPM refuse to start. |
| nginx `worker_processes` | ceil(CPU) 1–4 | same | same (+ `NGINX_WORKER_PROCESSES`) | |
| PHP capacity cap | `pm.max_children` × 4, 8–1024, as `limit_conn` in every PHP-bound location (429) | none | **same size, as upstream `max_conns` (503 + `Retry-After`)** | Without it a burst queues thousands of requests that each hold a worker for a minute and the capsule stays unresponsive for hours after the burst. `limit_conn` runs before the cache lookup, so at saturation it also shed cache HITs and any static file served through `location /`; counting FastCGI connections instead leaves cached pages and static files flowing, and a `503` with `Retry-After` is what CDNs and crawlers back off on. |
| `WP_MAX_MEMORY_LIMIT` | WordPress default (256M) | 512M | **sized: available memory clamped to 1–2 × `memory_limit`** (Basic 128M, Standard/Premium 256M, 2 GiB+ 512M) | One admin request at 256M is most of a Basic pod; the per-worker budget assumed 64M. Admin-ajax, admin-post and REST requests of an administrator get the same raise from the mu-plugin (core leaves them at the front-end limit, which is where page builders save and WooCommerce imports run). |
| ImageMagick `memory` / `map` | policy default (1 GiB / 2 GiB) | same | **2 × worker budget (64–256 MiB) / 2 × that, via `MAGICK_*` env** | The pixel cache is outside PHP's heap and `memory_limit`, inside the cgroup: a 24 MP phone photo is ~150 MB before a thumbnail is made. Past the limit ImageMagick spills to a temp file instead of growing. |
| `request_terminate_timeout` / nginx read timeout | 120s / 120s | same | **300s / 300s for `/wp-admin/*.php`, 120s public** | `max_execution_time` counts CPU time on this (non-threaded) build and never fires at 0.07–0.25 vCPU; the wall-clock kill is the only limit that does. WordPress budgets 300s for core/plugin upgrades (`set_time_limit(300)`), and a kill mid-upgrade leaves `.maintenance` in place for 10 minutes. The capacity cap bounds how many such requests can exist. |
| cached status codes | 200, 301, 302 | same | **200, 301** | A 302 is usually per visitor (WooCommerce geolocation, language/GeoIP redirects); WordPress page caches never store redirects. |
| WordPress `nocache_headers()` | ignored (`fastcgi_ignore_headers`) | same | **honoured as do-not-store**, 404s excepted | The documented WordPress API for "do not cache this"; the TTL still comes from `CACHE_TTL_SECONDS`. Anonymous 404s carry it too and stay cached for a minute. |
| `worker_rlimit_nofile` / `worker_connections` | 65536 / 16384 | default (1024) / 1024 | **sibling** | One nginx worker failed `accept()` with "Too many open files" at ~500 queued requests. |
| `request_slowlog_timeout` | 0 | 5s | **0** | Needs `ptrace`, forbidden by the capsule security context: every slow request only logged `failed to ptrace(ATTACH)`. nginx logs `rt=`/`urt=` per request. |
| FPM `listen` | `9000` (all interfaces) | `127.0.0.1:9000` | **this repo** | FastCGI from the pod network bypasses every nginx rule. |
| FPM `access.log` | on (upstream default) | `/dev/null` | **this repo** | nginx already logs each request; FPM's line duplicated it. |
| `fastcgi_keep_conn` / upstream `keepalive` | off / unused | **on / 32** | **off** | Defect, see §3. |
| page cache | off unless `CACHE_TTL_SECONDS` | on, 60s, purge on publish | **this repo** | The sibling's own load test shows capacity on small plans only comes from caching. |
| `DONOTCACHEPAGE` | not honoured | not honoured | **honoured** | Relayed to nginx as `X-CC-No-Cache`, hidden from clients. |
| rate limits | 120 / 30 / 60 r/m, 30 conn | 300 / 120 / 30 / 300 r/m, 100 conn | **this repo** | The 2026-10-23 audit found the lower values 429'd editors and NAT'd teams. |
| cron trigger | opt-in, 300s | on, 60s | **this repo** | Scheduled posts and Action Scheduler expect a minute. |
| `max_execution_time` / `request_terminate_timeout` / `fastcgi_read_timeout` | 60 / 120s / 120s | same | same | See §4. |
| `merge_and_write_config` | `NR == FNR` | same | **`FILENAME == ARGV[1]`** | With an empty override the idiom matched the defaults too and the generated files lost every comment and blank line (cosmetic, but the sized files now explain themselves inside a pod). |

Everything else in php.ini (`expose_php`, `cgi.fix_pathinfo`, `max_input_vars = 3000`,
`upload_max_filesize`/`post_max_size` from `MAX_UPLOAD_SIZE`, error handling to stderr,
`zend.assertions = -1`, `output_buffering`, session cookie flags, realpath cache 4096K/600,
`opcache.validate_timestamps = 1` / `revalidate_freq = 60`, `max_accelerated_files = 20000`,
`jit_buffer_size = 0`, `allow_url_include = Off`) and in the pool (`pm.max_requests = 500`,
`emergency_restart_*`, `process_control_timeout = 10s`, `clear_env = no`,
`security.limit_extensions = .php`, status/ping paths) is identical in both repos and was kept.

### What the sizing produces

| Plan | Memory | CPU | `memory_limit` | `WP_MAX_MEMORY_LIMIT` | opcache | `pm.max_children` | in-flight cap | nginx workers |
|---|---|---|---|---|---|---|---|---|
| Basic | 0.28 GB | 7% | 128M | 256M | 96M | 3 (floor, WARNING logged) | 12 | 1 |
| Standard | 0.6 GB | 15% | 128M | 256M | 96M | 3 (floor, WARNING logged) | 12 | 1 |
| Premium | 1 GB | 25% | 128M | 256M | 160M | 3 (r3: 12) | 12 | 1 |
| Custom | 2 GB | 1 | 256M | 512M | 256M | 12 | 48 | 1 |
| Custom | 4 GB | 2 | 256M | 512M | 256M | 24 | 96 | 2 |
| Custom | 8 GB | 4 | 256M | 512M | 256M | 48 | 192 | 4 |

## 2. Behaviour changes for capsules moving from r3 to r4 (announce)

- Pools on Premium shrink from 12 workers to 3; requests past 12 FastCGI connections get `503` +
  `Retry-After` with a holding page at once instead of waiting, while cached pages and static files
  keep being served. On the sibling's replayed production burst that turned "~1 % served, then
  OOM-killed" into "274 pages served, idle 30 s after the burst".
- `memory_limit` 128M (was 256M) on plans below 1.5 GiB; `WP_MAX_MEMORY_LIMIT` 128M on Basic and
  256M on Standard/Premium (was 512M everywhere). A site that genuinely needs more pins
  `memory_limit` in `WORDPRESS_CUSTOM_INI`, and the pool shrinks to match.
- Admin requests (and an administrator's admin-ajax/REST requests) may run up to 300s instead of
  being cut at 120s; huge image uploads get slower instead of risking an OOM-kill; a plugin's
  `Cache-Control: no-cache` and `DONOTCACHEPAGE` now keep a page out of the cache; 302s are no
  longer cached.
- No more 60 s stalls / 504s once concurrency exceeds the pool (§3): this is the change most
  visitors will notice.
- Pages a plugin marks `DONOTCACHEPAGE` are no longer served from the page cache.

## 3. Defects found on the way

1. **FastCGI keep-alive pinned PHP-FPM workers (r1–r3, shipped).** `fastcgi_keep_conn on` with
   upstream `keepalive 32`: PHP-FPM cannot multiplex, so after a request the worker blocks reading
   the kept connection until nginx closes it (60 s idle). Measured on `php8.4-r3` with a 3-worker
   pool and 10 concurrent 3-second requests: 3 served in 3 s, 3 at 66 s (after nginx's idle
   timeout released the workers), 4 × 504 at 120 s. With keep-alive off: all 10 in 12 s. Every
   capsule on r1–r3 behaves this way as soon as concurrency exceeds its pool, which is 3 on
   Premium. Both directives removed; the `inflight-cap` smoke check would now catch a regression
   (its 12 admitted requests must all complete).
2. **CPU bound rounded up to whole cores (r1–r3).** `cgroup_cpu_limit` returned `ceil(quota)`,
   so 0.07–0.25 CPU counted as one core and allowed 12 workers wherever memory permitted.
3. **`WP_MEMORY_LIMIT` would have defeated a sized `memory_limit`.** WordPress's
   `wp_initial_constants()` raises `memory_limit` to the constant when the constant is higher.
   The prepend now derives both constants from the ini value.
4. **`request_slowlog_timeout = 5s` only produced `ptrace` errors** in the capsule (no
   `CAP_SYS_PTRACE`), one per slow request, with no trace.
5. **Generated config files lost their comments** whenever no override was set (`NR == FNR`
   with an empty first file).

## 4. Review of the base values: what was left as is, and why

- **`max_execution_time = 60`.** Counts CPU time via `setitimer(ITIMER_PROF)` on this build, so it
  is not the limit that fires; it stays at 60 (a busy loop is still cut) with a comment saying so.
  The wall-clock limits were changed instead (table above).
- **`max_input_vars = 3000`.** Enough for menus with ~100 items; raise to 5000 only if a site
  reports truncated menus or forms (cost is nothing until used). Kept at 3000 for parity.
- **`post_max_size = upload_max_filesize`.** A multipart upload whose fields plus file exceed the
  limit fails with a generic error. Harmless with the single `MAX_UPLOAD_SIZE` knob; a site that
  hits it raises that knob.
- **`disable_functions` left commented.** One site per container: disabling `exec` and friends
  buys no isolation (a compromised plugin already runs as `www-data`), and image-optimisation
  plugins and WP-CLI need them.
- **`opcache.jit_buffer_size = 0`.** Tracing JIT gives WordPress a few percent and has crashed
  with some extensions; not a plug-and-play default.
- **`opcache.validate_timestamps = 1` / 60 s.** Default capsules update WordPress on the
  volume, so timestamps must be validated; WordPress's upgrader invalidates files it writes, so
  updates apply immediately anyway. Git capsules could run with `0`; the gain is a `stat()` per
  file per minute per worker, not worth a divergent image.
- **nginx `open_file_cache`.** Would save three `stat()` calls per pretty-URL request on the NFS
  docroot (`if (!-e …)` plus `try_files`), but caches a replaced file's old inode for its validity
  window, which bites plugin updates. Milliseconds against page renders of hundreds of
  milliseconds; not worth the staleness.
- **`/healthz` and the cron trigger use the uncapped upstream.** With the cap, a saturated pool
  would answer the probe `503` at once and Kubernetes would restart the pod under load; uncapped,
  the probe waits for a worker (a slow probe, not a failed one) and the cron trigger queues instead
  of being shed for the length of a burst. The platform follow-up from the 2026-10-23 audit stands:
  liveness probes on `/healthz` need a generous timeout, or stay on TCP, with HTTP for startup and
  readiness only.
- **The Basic plan.** 3 workers on 0.28 GB plans ~355 MB of PHP in the worst case; a light site
  idles far below that, a WooCommerce site should not be there at all. The boot log says so. The
  audit's recommendation to default new WordPress capsules to 512Mi / 250m stands.
- **Outbound email, object cache, login lockout** remain the roadmap items they were.

## 5. Review panel

Three independent reviewers read the working tree after the first round, one per lens (WordPress
compatibility of the defaults; nginx and PHP-FPM runtime correctness; the sizing model and the
shell), with the sibling repo and its load-test record for comparison, and reproduced what they
reported (in the shipped image, in nginx 1.22 with the repo's config, in the test suite on Debian
with mawk and on macOS). All three verdicts: the defaults are sound for most WordPress sites and
the arithmetic holds across the plan range. 19 findings, each verified by hand before acting:

Applied in this revision:

1. **ImageMagick's pixel cache was outside the memory model** (policy: 1 GiB per image): bounded
   from the sizing via `MAGICK_MEMORY_LIMIT` / `MAGICK_MAP_LIMIT`, logged, smoke-tested through
   php-fpm.
2. **`WP_MAX_MEMORY_LIMIT` floor of 256M let one admin request use most of a Basic pod**: sized
   (table in §1); **admin-ajax / admin-post / REST never got the admin raise**: the mu-plugin
   applies it for administrators.
3. **The 120 s wall-clock kill was the only effective limit and WordPress budgets 300 s for
   upgrades**: 300 s in the pool and for the admin PHP location, 120 s public, comment on
   `max_execution_time` corrected.
4. **Redirects were cached for the TTL** (per-visitor 302s handed to everyone): only 200 and 301
   are stored.
5. **`DONOTCACHEPAGE` was sampled at one instant** and missed plugins that define it and exit
   earlier (SEOPress, feeds) or during rendering: the mu-plugin now opens an output buffer before
   any other `template_redirect` callback and sets the marker when the response is produced (256 KB
   chunks, so streamed responses stay flat); the early check is kept as a fast path; the
   define-then-exit case is in the smoke test.
6. **WordPress's own `nocache_headers()` were discarded** by `fastcgi_ignore_headers`: honoured as a
   do-not-store signal (404s excepted), while the TTL still comes from `CACHE_TTL_SECONDS`.
7. **Cache HITs and static files through `location /` were shed at the cap** (`limit_conn` runs
   before the cache lookup and holds a slot for a whole download): the cap moved to upstream
   `max_conns`, which counts real FastCGI connections; shedding answers `503` + `Retry-After` with a
   holding page instead of `429`. This also removed the per-request `limiting connections` error
   line and the need to restate the per-IP limit in ten locations.
8. **The cron trigger was shed by the cap** for the length of a burst: the loopback cron location
   (and `/healthz`) use an uncapped upstream and queue instead.
9. **A pinned `pm.max_children = 4 ; comment` (or `"4"`) was rejected by the sizing's parser**
   while PHP-FPM accepted the line, so the spares stayed at the sized values and PHP-FPM refused to
   start, the exact failure the feedback loop exists to prevent; the same gap left a quoted
   `memory_limit` out of the sizing. The parser now reads values the way PHP's ini scanner does.
10. **A pinned `memory_limit` of 1M crash-looped the pod** (division by zero in the worker budget):
    treated like an unparseable value, and the budget can no longer be 0.
11. **The forced-floor WARNING claimed a memory overrun on Standard**, where only the CPU bound was
    below the floor and the budget fit: the message now distinguishes the three cases (a limit at
    or above the container, a budget that does not fit, a CPU-bound floor); the readme said the
    same and was corrected.
12. **Missing tests**: a merge-library test (empty override keeps comments, CRLF, sections, last
    wins), the pinned-override cases above, and a smoke container that boots with a commented
    `pm.max_children` and a quoted `memory_limit` and passes `php-fpm -t`.

Documented, not changed:

13. **`wp_mail()` cannot deliver**: the image ships no mail transport (`sendmail_path` points at a
    binary that does not exist). Noted in the readme; a relay driven by `SMTP_*` variables (msmtp
    plus `sendmail_path`) is a feature of its own and the roadmap's P0 item, proposed separately.
14. **`/healthz` depends on a free worker** (PHP-FPM answers `ping.path` in a child): kept, uncapped
    (above); the probe guidance is in the readme and the platform follow-up list.

Not applied:

15. **Static upload types outside the asset regex served through `location /`**: moot once the cap
    counts upstream connections; the asset list was left alone because adding more types changes
    their browser-cache headers.
16. **Each shed request logs an error line**: `limit_conn_log_level notice` no longer applies;
    nginx logs `no live upstreams` at error level per shed request and OSS nginx cannot lower that.
    One line per shed request at burst rate is the same volume the sibling accepted.

The panel also confirmed: the generated configuration passes `nginx -t` in every variant
(defaults; XML-RPC + public cron + debug headers; cache off); the `FILENAME == ARGV[1]` idiom is
correct on the image's mawk 1.3.4 and on BSD awk; the suite passes identically on Debian bash 5.2
and macOS bash 5.3; the keep-alive removal is complete; `worker_rlimit_nofile 65536` is under the
524288 hard limit measured in capsules; cgroup v1 sentinels, `cpu.max max`, sub-100m quotas and
256M containers are handled.

## 6. Verification

- `bash tests/run.sh` (Homebrew bash 5.3; the panel also ran it on Debian bash 5.2 with mawk):
  3,391 assertions, 0 failed, over four files: cgroup v1/v2 detection; the sizing model across 170
  size/CPU combinations (spare-pool, budget, admin-limit and ImageMagick invariants, floor
  reporting, knobs, pinned overrides with comments and quotes, the 1M limit, host fallback, the
  three warning branches); the merge library (empty override keeps comments and blank lines, CRLF,
  sections, last wins); and the three configure scripts against fake cgroups with and without
  overrides, including every nginx fragment and the static configuration they rely on. Runs in CI
  as the `unit` job of the `runtime` workflow.
- `runtime/prepend.php` exercised with the local PHP 8.4 at `memory_limit` 128M / 256M / 1G / -1 /
  2048K, with and without `CC_SIZING_WP_MAX_MEMORY_LIMIT_MB` in the environment, and with owner-
  and env-defined constants: the expected values in every case.
- Keep-alive experiment on `php8.4-r3` (§3).
- Capacity-cap probe on `php8.4-r4` (1 GiB / 0.25 CPU, pool of 3, cap 12): 30 concurrent
  5-second cache-bypassed requests gave 12 × 200 in four rounds (5 s, 10 s, 15 s, 20 s) and
  18 × 503 in under 5 ms each, with the busy page and `Retry-After: 5`, and one `no live upstreams`
  error line per shed request. The same burst against a cacheable URL was rendered once and served
  29 times from the cache from behind `fastcgi_cache_lock` with nothing shed (2 active workers),
  which is the behaviour panel finding 7 asked for.
- `tests/smoke.sh` on `php8.4-r4` (built locally, amd64 under emulation): 32/32 checks pass. New
  or changed in r4: `sized-limits` (a `--memory 1g --cpus 0.25` container: 3 workers, 128M,
  OPcache 176M, `max_conns=12`, and through php-fpm `WP_MEMORY_LIMIT` 128M, `WP_MAX_MEMORY_LIMIT`
  256M, ImageMagick 128/256 MiB), `inflight-cap` (20 concurrent cache-bypassed 2 s requests: the
  admitted ones complete, the rest are immediate 503s with the busy page; with the r3 keep-alive
  this check fails with 000s), `pinned-overrides` (`pm.max_children = 4 ; keep it small` and
  `memory_limit = "192M"` boot, pass `php-fpm -t`, re-derive the spares and the cap, and are
  logged), `donotcachepage` (define at `template_redirect`, and define-then-exit), `metrics`
  asserting the `cc_runtime_*` gauges, and `prepend-respects-owner` with a positive control (the
  old check never loaded the prepend: `php -r` does not run `auto_prepend_file`, so it passed
  vacuously). Tracks 8.3 and 8.5 share every changed file and are built and smoke-tested by CI on
  the PR.
