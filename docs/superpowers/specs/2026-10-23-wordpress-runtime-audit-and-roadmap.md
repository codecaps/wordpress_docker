# WordPress runtime — production-readiness audit and roadmap

Date: 2026-10-23 · Scope: `wordpress_docker` (feat/wordpress-runtime), capsule-api
(feat/wordpress-php-runtime), site (feat/wordpress-php-version), infra-cluster-pipelines
(feat/wordpress-runtime-image) · Method: full read of the four branches, a 4-agent audit
(security, performance/compatibility, integration, competitors — every finding verified against
the built image or the code), fixes applied to the runtime, and a 27-check smoke test per PHP track.

## 1. Where the migration stands

| Piece | Branch | State |
|---|---|---|
| Runtime image | `wordpress_docker` `feat/wordpress-runtime` | Complete + hardened (this audit). Builds `php8.3-r1`, `php8.4-r1`, `php8.5-r1`. **Not pushed** (10 commits ahead of `origin/main`; `origin/main` even lacks the PHP2Shell hotfix). |
| Capsule API | `feat/wordpress-php-runtime` (worktree `.worktrees/capsule-api--feature`) | Complete per plan + r2 tags + database creation; 876 unit tests pass; image `capsule-api:0.3.426.featwordpress-php-runtime.b68dcbb6` deployed to cc-proxmox. **No upstream branch, not pushed.** |
| Site | `feat/wordpress-php-version` | Complete; 1127 Karma specs, `build:prod`, `tsc`, all guard scripts pass. **Not pushed.** |
| Tekton task | `feat/wordpress-runtime-image` (worktree `.worktrees/infra-cluster-pipelines--runtime`) | Complete. **Not pushed.** |
| Registry | `europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime` | **Pushed 2026-10-23**: `php8.3-r1`, `php8.4-r1`, `php8.5-r1` (plus the moving aliases) — exactly the tags in capsule-api's `WORDPRESS_RUNTIME_TAGS`. Capsule API image `capsule-api:0.3.426.featwordpress-php-runtime.97ab51cd` built locally, not pushed. |

The API↔site contract is consistent (enum values, `8.4` default, `phpVersion: null` for legacy
capsules, old-site bodies carrying `version`, git capsules rebuild instead of redeploy) and each
of the plan's five "review focus" items has a unit test.

## 2. Rollout order (hard constraints)

1. ~~Push the runtime images~~ — done 2026-10-23 (`php8.3-r1`, `php8.4-r1`, `php8.5-r1`); they must be in the registry **before** capsule-api or the Tekton task ship.
2. Merge `feat/wordpress-runtime` → `main` and push **before** deploying the Tekton task: it
   clones `codecaps/wordpress_docker` at `main` and needs `git/Dockerfile` there. Pin
   `WP_RUNTIME_REF` to a tag/sha in the Tekton task rather than `main` (follow-up).
3. Confirm the tenant image-pusher service account can **pull** `appstrax/main/wordpress-runtime`
   (kaniko now pulls a private base instead of Docker Hub). Run one git build per cluster type.
4. Deploy capsule-api to **every** cluster, then the site: the new site omits `version`, which the
   old API still requires on create and on the runtime-config PUT.
5. Verify on a test capsule that the access log's `xff=… realip=…` show the true visitor IP both
   directly and through a Cloudflare-proxied domain (Traefik `forwardedHeaders.trustedIPs`). If
   not, every visitor shares one rate-limit bucket.
6. Announce, then retrofit: dry run → canary → all (plan "Revisions (2026-10-22)").

## 3. What the audit found and what is fixed in the image

Verified defects fixed in `wordpress_docker` (details: plan "Revisions (2026-10-23)"):

| Area | Defect | Fix |
|---|---|---|
| Deploys | Image `STOPSIGNAL` is `SIGQUIT`, `run.sh` trapped only TERM/INT → every stop hung 30s then SIGKILL (exit 137), in-flight requests dropped | `STOPSIGNAL SIGTERM`; TERM/INT/QUIT handled; graceful `QUIT` to nginx and php-fpm with a bounded wait |
| Deploys | nginx accepted traffic (and passed the TCP probe) before php-fpm / the first-boot core copy → 502/404 window | php-fpm starts first; nginx waits until it listens |
| Security | PHP-FPM listened on `[::]:9000` (upstream `zz-docker.conf` overrode the pool file) → FastCGI reachable from the pod network, bypassing nginx | `listen = 127.0.0.1:9000` in `zzz-custom.conf`; smoke-tested |
| Security | `add_header` inheritance dropped every security header on static assets, and `DEBUG_HEADERS=true` removed them from all PHP responses | headers-more module (`more_set_headers`, additive) |
| Security | `wp-config.old`, `*.sql`, plugin `changelog.txt`, drop-ins served | denied (404) |
| Security | HSTS `includeSubDomains` default on customer apex domains; deprecated `X-XSS-Protection`; CSP blocked `wss:` | `HSTS_HEADER` env (default `max-age=31536000`); header removed; `connect-src … wss:` |
| Security | Exporters downloaded unverified and run as root; PhpRedis unpinned; no `php.ini`; ImageMagick PostScript coders open | sha256/sha512 checks, `www-data`, `redis-6.3.0`, `php.ini-production`, PS/EPS/XPS/MVG/MSL closed |
| Security | File editors on by default on a writable docroot | `DISALLOW_FILE_EDIT` default via the prepend (`WP_DISALLOW_FILE_EDIT=false` to re-enable) |
| Ops | nginx logs written to files inside the container (no rotation, invisible to Loki) | stdout/stderr |
| Ops | Owner env values (`CSP_HEADER` with quotes/`$`, broken `NGINX_EXTRA_CONF`, bad `CACHE_*`) crash-looped the pod | validated / disabled with a loud log; site stays up |
| Ops | `MAX_UPLOAD_SIZE=64MB` → PHP limit 64 bytes | one validator for nginx and PHP |
| Perf | Page cache off by default; nothing in the platform turned it on | on by default (`CACHE_TTL_SECONDS=60`; `0` disables) |
| Perf | No purge path | `ngx_cache_purge` module + token-protected loopback purge location + runtime mu-plugin (purge on content changes, admin-bar button, `wp cc cache purge`) |
| Perf | Bypass regexes over-matched (`~*s=` hit `?tags=`, `^/cart/?` hit `/cartoons/`) | anchored |
| Perf | FPM pool fixed at 12 children / OPcache 256M / `worker_processes auto` whatever the pod size | sized from cgroup memory and CPU limits |
| Perf | Rate limits too low for wp-admin / REST (429s for editors, teams behind NAT) | new defaults + separate login zone |
| Correctness | HTTPS never signalled to PHP for git capsules; nginx redirects downgraded to `http://` | `HTTPS`/`REQUEST_SCHEME`/`SERVER_PORT` from `X-Forwarded-Proto`; `absolute_redirect off`; prepend sets `$_SERVER['HTTPS']` |
| Correctness | `DISABLE_WP_CRON` undefined (doomed loopback spawn every page load); cron every 5 min | defined by the prepend; interval 60s |
| Observability | `wp-metrics.php` autoload query missed WP ≥ 6.6 values; no core version | fixed; `wordpress_core_version_info` |
| DX | No WP-CLI | WP-CLI 2.12.0 |

The platform prepend (`runtime/prepend.php`, via `auto_prepend_file`) and the runtime mu-plugin
(`runtime/mu-plugins/code-capsules.php`, loaded through WordPress's pre-initialised hooks) put
no files on the customer's volume, never override a constant the site defines, and are switched
off with `WP_RUNTIME_PREPEND_ENABLED=false` / `WP_RUNTIME_MU_PLUGIN_ENABLED=false`.

### Behaviour changes for existing capsules (announce before the retrofit)

Page cache on (60s, purged on publish; logged-in users always bypass), file editors off,
`WP_MEMORY_LIMIT` 256M, cron every minute, new rate limits (more generous), HSTS without
`includeSubDomains`, XML-RPC off unless the retrofit set `XMLRPC_ENABLED=true`. Git capsules
additionally move from 24 to a cgroup-sized FPM pool.

## 4. Platform-side follow-ups (capsule-api / infra / site)

Ordered by value; none is needed for the first test deployment.

1. **Probes**: default WordPress probes to `httpGet /healthz` (startup window large enough for
   the first-boot copy on NFS). TCP works now that nginx waits for FPM, but liveness on TCP never
   restarts a wedged FPM. `wordpress-deployment.service.ts probes()`.
2. **Default resources**: 256Mi/100m is below any competitor's smallest WordPress plan; the pool
   auto-sizes to 2 workers there. Default new WordPress capsules to 512Mi/250m.
3. **Visible defaults at create**: seed `CACHE_TTL_SECONDS=60` (and optionally `MAX_UPLOAD_SIZE`,
   `XMLRPC_ENABLED`) as `ConfigSetBy.USER` configs so users see and can edit what the image does.
4. **Scrape the exporters**: a PodMonitor for `codecapsules.io/type=wordpress` pods on 9113/9253
   (and expose `/wp-metrics` on a pod port); surface FPM saturation and cache hit ratio in the UI.
5. **Retrofit git capsules' `phpVersion`** (`adopt(capsule,'8.5')` + save, no k8s action) so the
   UI stops saying "Legacy image" for capsules whose next build already uses the runtime.
6. **Tests**: extract the retrofit step of `redeploy-wordpress-capsules.ts` and unit-test
   dry-run vs apply ordering; add a `oneOf` test for the old-site runtime-config body.
7. **Tekton**: pin `WP_RUNTIME_REF`, pin the git/kaniko step images, grant the pusher SA read on
   the runtime repo (IAM).
8. **Narrow `TRUSTED_PROXY_CIDRS`** to the Traefik pod CIDR per cluster (env on the Deployment).
9. **Service type**: `ClusterIP` instead of `NodePort` (Traefik routes by name).
10. **PHP lifecycle**: EOL dates per track, UI banner/email 90/30 days out, auto-move after EOL.

## 5. Competitors: what a fresh WordPress gets elsewhere

Sources: official docs/pricing pages read on 2026-10-23 (Kinsta, WP Engine, Flywheel, Pressable,
Cloudways, SiteGround, Pantheon, Upsun, Rocket.net, Hostinger, DigitalOcean, Railway, Render,
AWS Lightsail, Google Click-to-Deploy). Managed hosts set the bar; PaaS templates are the direct peers.

| Default | Managed hosts | PaaS / cloud templates | Code Capsules (after this work) |
|---|---|---|---|
| Full-page cache + purge on publish | All (WP Engine 10 min, Pantheon 600s + surrogate-key purge, Pressable 5 min, SiteGround, Kinsta) | Upsun router cache; none on Railway/Render/DO | **Yes** (60s, purge on content change, admin bar, CLI) |
| Object cache | Pressable always on; Pantheon/Cloudways/Rocket.net on higher plans; Kinsta add-on | Railway Pro (Redis plugin enabled) | PhpRedis + `WP_REDIS_*` from env; plugin still manual |
| CDN / edge cache | Kinsta, Pantheon, Pressable, Rocket.net, SiteGround, Flywheel | none | none (CDN-ready headers) |
| PHP choice | 8.2–8.5 (Kinsta only other with 8.5) | fixed 8.3/8.4 | **8.3/8.4/8.5, user-switchable** |
| WP-CLI / shell | all (SSH + WP-CLI) | Railway/Upsun/Lightsail/DO (WP-CLI) | **WP-CLI** in image; no shell/exec in the UI |
| Staging / clone | all managed hosts | Upsun previews | none |
| Backups | daily files + DB, 7–30 days, one-click restore | Railway Pro nightly | MySQL capsule backups only; no files volume backup |
| Email | Pressable relay; others document SMTP plugins | guides point at SMTP plugins | none (no MTA; `wp_mail()` fails silently) |
| Security | login protection, WAF, malware scan, strong passwords, Jetpack Protect | minimal | headers, rate limits, XML-RPC off, file blocks, editors off; no WAF/lockout/scan |
| Updates | core auto-updates (Pressable release day; SiteGround/Hostinger managed) | WordPress defaults | WordPress defaults |
| Observability | Kinsta APM free, Pantheon New Relic, Cloudways metrics | none | Prometheus exporters + WP metrics (not yet scraped), logs in platform |
| Brotli / HTTP/3 | WP Engine, Pressable, Kinsta (edge) | none | gzip (nginx has h2/h3 compiled; TLS at Traefik) |
| Safe first boot | Railway Pro, DO, Lightsail generate admin credentials before public | | `/wp-admin/install.php` public until the owner installs |

Where the runtime is at parity or ahead of the PaaS group: PHP choice and patch cadence
(immutable tags, digest pins, Renovate, MIN_PHP gate), nginx hardening and headers, WooCommerce-aware
cache rules with stale-while-revalidate, cgroup-sized FPM, Cloudflare-aware real IP, platform-run
cron with heartbeat metric, in-container Prometheus exporters, FPM-aware health endpoint, graceful
deploys, editable PHP/FPM/nginx config, logs in the platform viewer.

## 6. Roadmap to "best possible WordPress experience"

**P0 — before or with the first customer-facing release**
- Outbound email: a runtime mu-plugin `phpmailer_init` hook configured from
  `WP_SMTP_HOST/PORT/USER/PASSWORD/ENCRYPTION/FROM` (small), an "Email" section in the capsule
  config, and an admin notice when nothing is configured; later a platform relay (SES/Postmark)
  with per-domain DKIM. Password resets and WooCommerce order mails do not work today.
- Scrape and show the metrics (PodMonitor; FPM saturation, cache hit ratio, cron heartbeat in the UI).

**P1 — next quarter**
- One-click object cache: "Add Redis" on create provisions + links a Redis capsule; the runtime
  drops in `object-cache.php` from a bundled, pinned Redis Object Cache plugin when `WP_REDIS_HOST` is set.
- Safe first boot: capsule-api generates admin credentials, run.sh runs `wp core install` before
  the site is public; `install.php` returns 503 while uninstalled.
- Login protection in the mu-plugin (lockout after N failures per IP+user, strong passwords for
  admins, block user enumeration) + `wordpress_login_lockouts_total`; plugin inventory in
  `wp-metrics` for vulnerability matching (WPScan/Patchstack).
- Files-volume backup paired with the MySQL backup (same timestamp), 7–14 day retention, restore.
- Update policy: `WP_AUTO_UPDATE_CORE=minor` default + opt-in plugin/theme auto-updates with
  purge afterwards.

**P2 — differentiators**
- CDN/edge: per-domain Cloudflare proxy option; `s-maxage` on cacheable HTML; CDN purge hook in the mu-plugin.
- Staging/clone: snapshot + `wp search-replace` into a `<name>-staging` pair, `WP_ENVIRONMENT_TYPE=staging`.
- "Open shell / Run command" in the UI (exec as www-data with WP-CLI); no sshd in the image.
- APM-lite: slow-request structured log line (URL, queries, time, memory, plugins) + gauges; a Performance tab.
- Brotli (`libnginx-mod-http-brotli-*` on trixie), WebP/AVIF output by default (`image_editor_output_format`).

**P3**
- PHP EOL lifecycle UI; WordPress core version shown in the UI (metric already exported).

## 6b. Live test on cc-proxmox (2026-10-23)

With `php8.x-r1` in the registry and the feature capsule-api deployed to `capsule-api` on cc-proxmox,
the site was run locally against the test platform and exercised in Chrome (space `static-test-xllb`):

- **Legacy capsule → runtime** (`wordpress-capsule-uufu`, `wordpress:6.8-php8.3.36`): the config card
  showed "Legacy image (keep current)"; choosing PHP 8.4 issued `PUT …/config/runtime` (200), added
  `XMLRPC_ENABLED=true`, rolled the Deployment to `wordpress-runtime:php8.4-r1` with the existing
  volume untouched; the site served 200 with the new headers, page cache MISS→HIT, XML-RPC reachable,
  `wp-config.php`/`debug.log` 404, nginx access and error lines visible in the platform Logs tab.
- **New capsule** (`runtime-test-php85-coep`, PHP 8.5, Basic plan, new storage capsule): created
  through the wizard; Deployment on `php8.5-r1`; core copied onto the empty NFS volume; `/` → 302 to
  the installer, installer 200, XML-RPC 403. **Defect**: the TCP startup probe killed the first
  container mid-copy (fixed in r2 with the 503 holding page; see the plan revisions).
- **Platform gaps found**: no database creation on the MySQL capsule (second site cannot install) —
  **fixed the same day in capsule-api** (`WordpressDatabaseService.ensureDatabase`, `CREATE DATABASE IF
  NOT EXISTS` as the MySQL capsule's root at the start of every WordPress deploy; names limited to
  `^[A-Za-z0-9_]+$`; capsule-api commit `b68dcbb6`);
  storage capsule shareable with no subPath (two sites, one docroot); Basic plan 0.28GB → 2 FPM
  workers (r3 raises the floor to 3 from measured usage); test cluster NAT hides visitor IPs;
  php-fpm's own access log duplicated nginx's lines (off in r3).

### Follow-through on cc-proxmox (same day)

- capsule-api `b68dcbb6` (database creation) and `ef933fbf` (r3 tags) deployed to `capsule-api` on
  cc-proxmox; 876 unit tests pass.
- Database creation verified through the UI: changing the test capsule's database name to a
  non-existent `runtime_test_php85_v2` and saving created the database on the MySQL capsule during
  the redeploy, and the installer loaded against it.
- Both test capsules were redeployed through the config card (PHP version changes) and now run
  `wordpress-runtime:php8.4-r3`: pool of 3 workers on the 0.28GB plan, FPM on loopback, single
  access-log stream, `/` 200 (legacy site) and 302 → installer (new site), no restarts.
- The config card's PHP dropdown needed element-level clicks in the automated browser (coordinate
  clicks on options did not register there, while they did in the create wizard) — worth a manual
  check that the ng-select in `wordpress-config.component` behaves normally for real users.

## 7. Test evidence

- capsule-api `npm run test:unit`: 870 passing.
- site: `tsc -p tsconfig.spec.json`, `check:layers|cycles|imports|signals`, Karma 1127/1127, `ng build --configuration production`: all pass.
- runtime `tests/smoke.sh` (27 checks: install, WP-CLI install, FPM loopback, logs on stdout,
  headers on static, HSTS, redirect scheme, prepend constants + owner precedence, cache HIT,
  bypass rules, purge on publish + CLI, login rate limit + log line, sensitive files, XML-RPC,
  upload-size sync, metrics, FPM sizing, graceful stop, existing volume, FPM-aware healthz,
  git variant, PHP version, extensions, ImageMagick policy): see the table below.

| Track | Build | Smoke |
|---|---|---|
| php8.4-r1 | ok | 27/27 |
| php8.3-r1 | ok | 27/27 |
| php8.5-r1 | ok | 27/27 |
| php8.3-r2 / php8.4-r2 / php8.5-r2 (holding page) | ok, pushed | 28/28 each |
| php8.3-r3 / php8.4-r3 / php8.5-r3 (pool floor 3, no FPM access log) | ok, pushed | 28/28 each |

(The first 8.4 run exposed a `pipefail` + `docker logs | grep -q` race in the smoke script itself,
now fixed; the images were unaffected.)

Pushed and built on 2026-10-23 after re-authentication: the three runtime images are in the
registry (`./push.sh` for each track), and the Capsule API image built with a fresh npm token
(`make docker-build` in `.worktrees/capsule-api--feature`); pushing it (`make docker-push`) and
deploying follow the rollout order in section 2.

Note for whoever runs builds locally: an audit agent pruned every local `wordpress*` image during
the audit (including the earlier r1 builds); nothing in the registry was touched.
