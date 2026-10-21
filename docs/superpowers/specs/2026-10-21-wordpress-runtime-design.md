# WordPress runtime images — design

Date: 2026-10-21 · Status: agreed in chat with Jacques, implementation in progress

## Problem

WordPress capsules pick a *WordPress version* (6.5–6.9) at create time. Each version is its own
image folder (`v_6.x/`) with its own base image, its own PHP minor and its own copy of the nginx /
PHP config. In practice:

- The version only matters on first boot. Default capsules mount the whole docroot
  (`/var/www/html`) on a PVC; the upstream entrypoint copies core in only when the volume is empty,
  and WordPress then updates itself. The "version" a capsule was created with is fiction a month
  later.
- Patching PHP means rebuilding five folders, and upstream stops rebuilding old version tags, so
  the old folders silently froze on old PHP (PHP2Shell, CVE-2026-109618/109619, exposed this).
- Images are deployed by moving tags with `IfNotPresent`, so a re-push never reaches running pods.
- Git capsules build per-capsule images from a second repo (`wordpress_git_docker`) whose config
  has drifted from this one.

## Decision

**The image is a PHP runtime; WordPress belongs to the volume (default) or the repo (git).**

1. One flat repo, one `Dockerfile`, parameterised by `BASE_IMAGE`. One *track* per PHP minor:
   `tracks/php8.3.env`, `php8.4.env`, `php8.5.env`, each pinning `wordpress:php8.x-fpm@sha256:…`
   plus `MIN_PHP_VERSION` and a `REVISION` counter.
2. Image: `europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php<minor>-r<REVISION>`,
   e.g. `wordpress-runtime:php8.4-r1`. Immutable: `push.sh` refuses to overwrite an existing tag.
   A moving `php8.4` alias is pushed for humans; **nothing deploys it.**
3. Git capsules use the same runtime: `git/Dockerfile` is `FROM ${RUNTIME_IMAGE}` + `COPY wp-html`.
   The Tekton task clones this repo and passes `RUNTIME_IMAGE`. `wordpress_git_docker` is archived.
4. Users choose a **PHP version** (8.3, 8.4 default, 8.5) at create time, for both deployment types,
   and can change it later on the config page (a redeploy for default capsules, a rebuild for git).
5. capsule-api stores `jsonManifest.phpVersion` and maps it to the runtime tag in code. Bumping a
   tag + running the redeploy job rolls a patched runtime to every capsule on that track.
6. Existing capsules are retrofitted by a capsule-api job: 6.5–6.8 → 8.3, 6.9 → 8.4, git → 8.5.
   Until a capsule is retrofitted it keeps its (hotfixed) legacy image.
7. WordPress core, plugins, themes and WordPress settings remain the customer's responsibility.

## Behaviour the retrofit changes, and what we do about it

| Change for capsules coming from 6.5–6.8 | Mitigation |
|---|---|
| XML-RPC returns 403 (`XMLRPC_ENABLED=false` default) — breaks Jetpack / mobile app | Retrofit writes `XMLRPC_ENABLED=true` as a user-visible config |
| Public `wp-cron.php` is blocked, and WordPress's loopback cron arrives via the ingress, so cron never runs (also true of v6.9 capsules today) | Runtime starts the in-container cron trigger **by default** (`WP_CRON_TRIGGER_ENABLED` defaults to `true`) |
| Rate limits, security headers, CSP, 64M uploads, FastCGI cache | Accepted; announce before the retrofit |

## Other runtime fixes folded in

- `wp-metrics.php` moves out of the docroot (`/usr/share/wp-runtime/`) — on a PVC-mounted docroot
  the image's copy was hidden and `/wp-metrics` 404'd.
- `/healthz` checks PHP-FPM, not just nginx. `run.sh` exits non-zero when nginx or FPM dies.
- Merge the git image's improvements (PhpRedis, `CACHE_SKIP_EMPTY`, admin FastCGI buffers,
  xmlrpc/wp-cron timeouts, cron trigger + its metrics). FPM defaults stay at v6.9's
  `max_children=12` (the git image's 24 came from an unexplained "lower workers test" commit);
  git capsules that need more set `WORDPRESS_FPM_CONF`.

## Out of scope (follow-ups)

- An admin HTTP endpoint + DB-tracked rollouts (the job covers it for now).
- Reporting each capsule's installed WordPress core version in the UI.
- Moving WordPress off MySQL `root`; the manual Deploy endpoint's generic-service routing.
- Deleting `legacy/` and the legacy image map once every capsule is retrofitted.
