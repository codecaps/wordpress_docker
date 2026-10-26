# WordPress Runtime Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-WordPress-version images with per-PHP-minor runtime images that every WordPress capsule (default and git) runs on, let users choose a PHP version instead of a WordPress version, and retrofit existing capsules.

**Architecture:** One parameterised `Dockerfile` in `wordpress_docker` builds `wordpress-runtime:php<minor>-r<n>`; git capsules layer their repo on top via `git/Dockerfile`. capsule-api stores `jsonManifest.phpVersion` and maps it to an immutable runtime tag in code; capsules without `phpVersion` keep their legacy image until a retrofit job assigns one. The site swaps the WordPress-version picker for a PHP-version picker (create wizard + config card).

**Tech Stack:** Docker/buildx + bash (wordpress_docker), LoopBack 4 / TS 4.9 / mocha (capsule-api), Angular 22 / signals / Karma (site), Pulumi TS + Tekton + kaniko (infra-cluster-pipelines).

**Spec:** `docs/superpowers/specs/2026-10-21-wordpress-runtime-design.md` (this repo)

## Branches

| Repo | Branch | Base |
|---|---|---|
| `wordpress/wordpress_docker` | `feat/wordpress-runtime` | `hotfix/php2shell` |
| `code_capsules_core/capsule-api` | `feat/wordpress-php-runtime` | `hotfix/wordpress-php2shell` |
| `code_capsules_core/site` | `feat/wordpress-php-version` | `origin/development` |
| `pulumi/infra-cluster-pipelines` | `feat/wordpress-runtime-image` (worktree `.worktrees/infra-cluster-pipelines--runtime`) | `origin/development` |

Before editing capsule-api or site, read `code_capsules_core/.claude/docs/repo-capsule-api.md` / `repo-site.md`.

## Global Constraints

- Runtime image repo: `europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime`.
- Runtime tag format: `php<minor>-r<REVISION>`; first release of every track is `r1` (`php8.3-r1`, `php8.4-r1`, `php8.5-r1`).
- PHP versions offered: `'8.3' | '8.4' | '8.5'`. Default for new capsules: `'8.4'`. Legacy git capsules map to `'8.5'`.
- `MIN_PHP_VERSION` per track: 8.3 → `8.3.36`, 8.4 → `8.4.27`, 8.5 → `8.5.12`.
- Legacy mapping (retrofit): `6.5|6.6|6.7|6.8 → '8.3'`, `6.9 → '8.4'`, unknown/missing default-type version → `'8.3'`, `deploymentType: 'git' → '8.5'`.
- Legacy 6.5–6.8 capsules being adopted get user config `XMLRPC_ENABLED=true` unless they already have an `XMLRPC_ENABLED` config.
- The capsule-api ↔ site contract (runtime config, `GET/PUT /capsules/{id}/config/runtime`):
  `{ phpVersion: '8.3'|'8.4'|'8.5'|null, version: string|null /* deprecated, read-only */, database, healthCheck, storageCapsuleId }`. `phpVersion: null` = still on its legacy image. On save, `phpVersion` omitted or `null` keeps the current value; `version` is ignored.
- Create manifest: `{ manifestType:'wordpress', deploymentType, phpVersion?, version? /* ignored */, repo?, sourceSubpath?, database, storageCapsuleId }`.
- Never deploy a moving tag. Never push images from these tasks; building locally is fine.

## Review Focus

1. **Old site, new API**: a create request with `version: '6.8'` and no `phpVersion` must create a capsule on `phpVersion '8.4'`, and a runtime-config PUT carrying `version` but no `phpVersion` must succeed without changing the PHP version. (Task B2, B3 tests.)
2. **Unrelated save on a legacy capsule**: saving only a health check on a capsule with no `phpVersion` must not adopt the runtime. (Task B3 test.)
3. **Git capsule PHP change**: changing `phpVersion` on a git capsule must start a build, not re-apply the old image. (Task B3 test.)
4. **Query-param tampering**: `/new?...&phpVersion=7.0` must fall back to `'8.4'`, not reach the manifest. (Task D1 spec.)
5. **Docroot-mounted volume**: with a PVC over `/var/www/html`, `/wp-metrics` (on :8080) and `/healthz` must still work, and an existing volume's core must be untouched by an image swap. (Task A5 smoke test.)

---

## Part A — `wordpress_docker` (runtime images)

### Task A1: Flat runtime layout with tracks

**Files:**
- Move: `v_6.9/{Dockerfile,run.sh,nginx.conf,default.conf,wp-metrics.php,cloudflare_ips.fallback.conf,scripts/}` → repo root (`git mv`)
- Move: `v_6.5 … v_6.9`, root `docker_build.sh`, `docker_push.sh` → `legacy/` (keep them buildable: `legacy/docker_build.sh 6.9` must still work; fix relative paths)
- Create: `tracks/php8.3.env`, `tracks/php8.4.env`, `tracks/php8.5.env`
- Modify: `Dockerfile`, `.gitignore`, `.dockerignore`

**Interfaces:**
- Produces: `tracks/php<minor>.env` with exactly `BASE_IMAGE=wordpress:php<minor>-fpm@sha256:<digest>`, `MIN_PHP_VERSION=<x.y.z>`, `REVISION=1`. `Dockerfile` accepts `--build-arg BASE_IMAGE` and `--build-arg MIN_PHP_VERSION`.

- [ ] **Step 1:** `git mv` the v_6.9 runtime files to the root and the five version folders + root build/push scripts into `legacy/`. Add `legacy/README.md`: "Images for capsules not yet retrofitted to a PHP runtime. Delete once capsule-api's legacy image map is gone."
- [ ] **Step 2:** Dockerfile: first lines become `ARG BASE_IMAGE` / `FROM ${BASE_IMAGE}` (no default — a build without a track must fail) followed by the existing `MIN_PHP_VERSION` guard (copy from `legacy/v_6.9/Dockerfile`, no default value). Add `LABEL org.opencontainers.image.source=https://github.com/codecaps/wordpress_docker`.
- [ ] **Step 3:** Write the three track files. Digest: `docker buildx imagetools inspect wordpress:php<minor>-fpm --format '{{json .Manifest.Digest}}'`. Use the digest of an image whose PHP ≥ `MIN_PHP_VERSION`; if upstream has not published one yet, pin the current digest and note it in the commit — the build guard will refuse it until bumped.
- [ ] **Step 4:** Verify: `docker buildx build . --build-arg BASE_IMAGE=wordpress:php8.4-fpm --build-arg MIN_PHP_VERSION=8.4.0 --load -t rt-test` succeeds; without `--build-arg BASE_IMAGE` it fails.
- [ ] **Step 5:** Commit `refactor: flatten into one runtime Dockerfile with PHP tracks`.

### Task A2: Merge the git image's improvements into the runtime

**Files:** `Dockerfile`, `run.sh`, `nginx.conf`, `default.conf`, `wp-metrics.php`, `scripts/configure_nginx_overrides.sh` (source of truth for the diff: `/Users/jacques/development/code_capsules/wordpress/wordpress_git_docker` at `origin/main`)

- [ ] **Step 1:** Port, verbatim where possible: the PhpRedis `RUN` block; `CACHE_SKIP_EMPTY` + `$cache_skip_empty` map; 120s `fastcgi_read_timeout`/`fastcgi_send_timeout` on xmlrpc/wp-cron; larger FastCGI buffers for `wp-admin/*.php`; the wp-cron trigger loop in `run.sh` and its two metrics in `wp-metrics.php`.
- [ ] **Step 2:** `WP_CRON_TRIGGER_ENABLED` defaults to `true` (`${WP_CRON_TRIGGER_ENABLED:-true}`); `false` disables it. Do **not** port the git image's FPM defaults — keep `max_children=12/start=3/min_spare=3/max_spare=6/max_requests=500`.
- [ ] **Step 3:** `diff -r` the root against `wordpress_git_docker` (excluding `wp-html`, `.git`, `Dockerfile` COPY of wp-html, FPM defaults) — expected: no other differences. Commit `feat: merge git image improvements; cron trigger on by default`.

### Task A3: Runtime fixes — metrics path, FPM-aware healthz, exit codes

**Files:** `Dockerfile`, `nginx.conf:197-201`, `default.conf` (`/healthz`), `run.sh`

- [ ] **Step 1:** `COPY wp-metrics.php /usr/share/wp-runtime/wp-metrics.php`; nginx `SCRIPT_FILENAME /usr/share/wp-runtime/wp-metrics.php`; in the file replace `require dirname(__FILE__) . '/wp-load.php'` with `require '/var/www/html/wp-load.php'`.
- [ ] **Step 2:** `/healthz` passes to FPM's ping path (`/fpm-ping`, `fastcgi_pass` to the FPM upstream, `access_log off`) so it returns non-200 when FPM is down.
- [ ] **Step 3:** `run.sh`: when `wait -n` returns, capture its status and `exit` with it after `_shutdown` (a TERM-initiated shutdown still exits 0).
- [ ] **Step 4:** Commit `fix: serve wp-metrics outside the docroot, FPM-aware healthz, propagate exit codes`.

### Task A4: Git capsule Dockerfile

**Files:** Create `git/Dockerfile`, `git/.dockerignore`, `git/README.md`

**Interfaces:** Produces the contract the Tekton task (Task C1) relies on: context `git/`, user repo cloned to `git/wp-html`, `--build-arg RUNTIME_IMAGE=<full image ref>`.

- [ ] **Step 1:** `git/Dockerfile`: `ARG RUNTIME_IMAGE` / `FROM ${RUNTIME_IMAGE}` / `COPY --chown=www-data:www-data ./wp-html /var/www/html`. No default for `RUNTIME_IMAGE`.
- [ ] **Step 2:** `git/.dockerignore` excludes `wp-html/.git`. README documents the contract above.
- [ ] **Step 3:** Commit `feat: git capsule image layered on the runtime`.

### Task A5: Build, push and smoke-test scripts

**Files:** Create `build.sh`, `push.sh`, `tests/smoke.sh`; rewrite `docker_run.sh`, `readme.md`

**Interfaces:**
- `./build.sh <minor> [buildx args…]` → builds `wordpress-runtime:php<minor>-r<REVISION>` and `:php<minor>`, `--platform linux/amd64 --load`, prints the immutable ref as the last line.
- `./push.sh <minor>` → fails (exit 1, message `tag already exists`) if `docker buildx imagetools inspect <immutable ref>` succeeds; otherwise pushes immutable then moving tag.
- `tests/smoke.sh <image-ref>` → exit 0 only if every check below passes.

- [ ] **Step 1: Write `tests/smoke.sh`** (pattern: `/private/tmp/…/scratchpad/hotfix_smoke.sh` from the hotfix; copy its MySQL/network setup). Checks, each printing `PASS <name>`/`FAIL <name>`:
  - `php-version`: `PHP_VERSION` ≥ the track's `MIN_PHP_VERSION` (pass min as `$2`)
  - `extensions`: `php -m` contains `redis`, `imagick`, `mysqli`, `opcache`
  - `install`: fresh volume → `GET /wp-admin/install.php` 200
  - `healthz`: 200; then `kill` php-fpm master inside the container → `/healthz` non-200 within 10s or the container exits non-zero
  - `metrics`: `docker exec … curl -s 127.0.0.1:8080/wp-metrics` contains `wp_cron_trigger_enabled 1`
  - `existing-volume`: seed a volume by running the image, write `wp-includes/version.php` `$wp_version = '6.5.5'` marker, restart on the same image → marker unchanged
  - `git-variant`: build `git/` with `RUNTIME_IMAGE=<image-ref>` and a stub `wp-html/index.php` printing `git-ok`; `GET /` contains `git-ok`
- [ ] **Step 2:** Run it against a deliberately broken image (comment out the PhpRedis block) → `FAIL extensions`, exit 1. Restore.
- [ ] **Step 3:** Write `build.sh`/`push.sh` per the interface; they `source tracks/php<minor>.env` and pass `BASE_IMAGE`/`MIN_PHP_VERSION` as build args. Unknown minor → exit 1 `unknown track`.
- [ ] **Step 4:** Run `./build.sh 8.4 --build-arg MIN_PHP_VERSION=8.4.0` (only while upstream is unpatched) then `tests/smoke.sh <ref> 8.4.0` → all PASS.
- [ ] **Step 5:** `readme.md`: layout, tracks, tag format, release procedure (bump digest + `REVISION` → build → smoke → push → bump capsule-api `WORDPRESS_RUNTIME_TAGS` → run the redeploy job), "never deploy the moving tag". Commit `feat: runtime build/push scripts and smoke test`.

### Task A6: Keep tracks current automatically

**Files:** Create `renovate.json`, `.github/workflows/runtime.yml`

- [ ] **Step 1:** `renovate.json`: regex manager over `tracks/*.env` matching `BASE_IMAGE=(?<depName>wordpress):(?<currentValue>php8\.\d-fpm)@(?<currentDigest>sha256:[a-f0-9]+)`, `datasourceTemplate: docker`, `pinDigests: true`, schedule `before 6am on monday`, plus a `postUpgradeTasks`-free note in the README that the PR author must bump `REVISION`.
- [ ] **Step 2:** Workflow on `pull_request`: matrix `[8.3, 8.4, 8.5]` → `./build.sh $m` → `tests/smoke.sh <ref> <MIN_PHP_VERSION>`; a step that fails if any `tracks/*.env` `BASE_IMAGE` changed without its `REVISION` changing (`git diff origin/${{ github.base_ref }} -- tracks/`). No push.
- [ ] **Step 3:** `actionlint` (or `docker run rhysd/actionlint`) passes. Commit `ci: build and smoke-test runtime tracks; renovate digest pins`.

---

## Part B — `capsule-api`

### Task B1: PHP version model and runtime image resolution

**Files:**
- Create: `src/capsule/capsule-types/wordpress-capsule/models/wordpress-php-version.ts`
- Create: `src/capsule/capsule-types/wordpress-capsule/wordpress-runtime-images.ts`
- Modify: `…/services/wordpress-deployment.service.ts` (`getWordpressImage`, `renderDefaultDeploymentSpec`, `createOrUpdateDeployment`)
- Test: `src/__tests__/unit/capsule/capsule-types/wordpress-deployment.unit.ts`

**Interfaces:**
- Produces:
  - `enum WordpressPhpVersion { V8_3 = '8.3', V8_4 = '8.4', V8_5 = '8.5' }`, `DEFAULT_WORDPRESS_PHP_VERSION = WordpressPhpVersion.V8_4`, `isWordpressPhpVersion(value: unknown): value is WordpressPhpVersion`
  - `WORDPRESS_RUNTIME_REPO = 'europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime'`, `WORDPRESS_RUNTIME_TAGS: Record<WordpressPhpVersion, string> = {'8.3':'php8.3-r1','8.4':'php8.4-r1','8.5':'php8.5-r1'}`, `wordpressRuntimeImage(php: WordpressPhpVersion): string`
  - `legacyWordpressPhpVersion(capsule: Capsule): WordpressPhpVersion` (the Global Constraints legacy mapping)
  - `WordpressDeploymentService.getWordpressImage(capsule)` — `phpVersion` set → `wordpressRuntimeImage(phpVersion)`; otherwise the existing legacy switch (unchanged hotfix tags).

- [ ] **Step 1: Failing tests** (`describe('WordPress runtime image')`):
  - `{phpVersion:'8.4'}` → `…/wordpress-runtime:php8.4-r1`; same for 8.3, 8.5
  - `{phpVersion:'8.4', version:'6.5'}` → runtime image (phpVersion wins)
  - `{version:'6.9'}` (no phpVersion) → `…/wordpress:6.9-php8.4.27` (legacy untouched)
  - `legacyWordpressPhpVersion`: 6.5→8.3, 6.8→8.3, 6.9→8.4, `undefined`→8.3, `{deploymentType:'git'}`→8.5
  - default spec sets `strategy` from `DeploymentStrategyUtility.buildDeploymentStrategyForSpec(capsule)` (same as the git spec) and `imagePullPolicy: 'IfNotPresent'`
- [ ] **Step 2:** `npm run test:unit` → those fail.
- [ ] **Step 3:** Implement. `createOrUpdateDeployment` records `imageUrl: data.image?.url ?? <the resolved default image>`.
- [ ] **Step 4:** `npm run test:unit` → all pass. Commit `feat(wordpress): resolve runtime image from phpVersion`.

### Task B2: Create manifest accepts `phpVersion`

**Files:** `…/models/wordpress-manifest-request.dto.ts`, `…/wordpress-capsule.ts` (`isManifestValid`), tests in `wordpress-deployment.unit.ts` (where `mapToCapsule` is already tested)

- [ ] **Step 1: Failing tests:** `mapToCapsule` with `phpVersion:'8.5'` → `jsonManifest.phpVersion === '8.5'` and no `version` key; with `version:'6.8'` and no `phpVersion` → `phpVersion === '8.4'`; `isManifestValid` → `true` for a default manifest without `version`, `false` for `phpVersion:'7.4'`.
- [ ] **Step 2:** Implement: add `@property({required:false, jsonSchema:{enum: Object.values(WordpressPhpVersion)}}) phpVersion?`; `version` stays optional and is no longer copied into `jsonManifest`; `isManifestValid` drops the version rule and rejects a present-but-invalid `phpVersion`.
- [ ] **Step 3:** Tests pass. Commit `feat(wordpress): create capsules with a PHP version`.

### Task B3: Runtime config `phpVersion` + adoption

**Files:**
- Create: `…/services/wordpress-runtime-adoption.service.ts` (bind `WordpressBindings.WORDPRESS_RUNTIME_ADOPTION_SERVICE` in `keys.ts` + `application.ts`)
- Modify: `…/models/wordpress-runtime-config.dto.ts`, `…/wordpress-capsule.ts` (`getRuntimeConfig`, `saveRuntimeConfig`, delete `nextVersion`), `…/enums.ts` (delete `VersionRequired`)
- Test: `src/__tests__/unit/capsule/capsule-types/capsule-runtime-config.unit.ts`

**Interfaces:**
- Produces: `WordpressRuntimeAdoptionService.adopt(capsule: Capsule, phpVersion: WordpressPhpVersion): Promise<void>` — sets `jsonManifest.phpVersion`; if the capsule had no `phpVersion`, is not git, and its legacy `version` is 6.5–6.8, adds config `XMLRPC_ENABLED=true` (`ConfigSetBy.USER`) via `ConfigService.setMany` unless an `XMLRPC_ENABLED` config exists. Does not save the capsule or redeploy.
- DTO: `phpVersion: WordpressPhpVersion | null` (`enum: [...values, null]`, not required); `version: string | null` (`readOnly: true`, ignored on save).

- [ ] **Step 1: Failing tests** (replace the `WORDPRESS_VERSION_REQUIRED` test):
  - GET returns `phpVersion: null` and `version: '6.8'` for a legacy capsule; `phpVersion: '8.4'` after adoption
  - PUT `{version:'6.8', database, healthCheck}` (old site) on a `phpVersion:'8.4'` capsule → `phpVersion` stays `'8.4'`, no error
  - PUT health-check-only on a legacy capsule → `phpVersion` still `null`, `adopt` not called (Review Focus 2)
  - PUT `phpVersion:'8.5'` on a legacy 6.7 default capsule → `adopt` called with `'8.5'`, redeploy called
  - PUT `phpVersion:'8.5'` on a git capsule → `startBuild(…, BuildType.MANUAL)` called, redeploy not called (Review Focus 3)
  - `adopt` unit: legacy 6.7 → `setMany` with `XMLRPC_ENABLED=true`; legacy 6.9 → no config; existing `XMLRPC_ENABLED` → no config
- [ ] **Step 2:** Run → fail. **Step 3:** Implement. `saveRuntimeConfig` change detection compares `{phpVersion, database, healthCheck}`. **Step 4:** Pass. Commit `feat(wordpress): change PHP version from runtime config`.

### Task B4: Git builds pass `RUNTIME_IMAGE`

**Files:** `src/build/configs/build-wordpress-taskrun.ts`; test next to existing build tests (`src/__tests__/unit/capsule/capsule-build.unit.ts`)

- [ ] **Step 1: Failing test:** params include `{name:'RUNTIME_IMAGE', value: wordpressRuntimeImage(capsule.jsonManifest.phpVersion ?? '8.5')}`.
- [ ] **Step 2:** Implement (capsule is reachable from `this.buildInput`; check `BuildTaskRun`). **Step 3:** Pass. Commit `feat(wordpress): build git capsules on the runtime image`.

### Task B5: Retrofit mode for the redeploy job

**Files:** `src/jobs/redeploy-wordpress-capsules.ts`

- [ ] **Step 1:** `REDEPLOY_WORDPRESS_RETROFIT=true`: before the default-capsule batches, every capsule without `phpVersion` gets `adopt(capsule, legacyWordpressPhpVersion(capsule))` then `capsuleRepo.save` (dry run: log only). Git capsules adopted this way are rebuilt only when `REDEPLOY_WORDPRESS_INCLUDE_GIT=true`.
- [ ] **Step 2:** Update the doc comment. `npm run lint` on the file and `npm run test:unit` pass. Commit `feat(wordpress): retrofit legacy capsules to PHP runtimes`.

---

## Part C — `infra-cluster-pipelines`

### Task C1: Tekton task builds on the runtime

**Files:** `src/tekton-tasks/resources/build-wordpress-image-from-git-task.ts`

- [ ] **Step 1:** `fetch-wp-base` clones `https://github.com/codecaps/wordpress_docker` at `$(params.WP_RUNTIME_REF)` (new param, default `main`). `fetch-wp-html` clones into `/workspace/docker-source/git/wp-html`. kaniko: `--dockerfile=/workspace/docker-source/git/Dockerfile`, `--context=/workspace/docker-source/git`, `--build-arg=RUNTIME_IMAGE=$(params.RUNTIME_IMAGE)`.
- [ ] **Step 2:** New param `RUNTIME_IMAGE`, default `europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php8.5-r1` (so a capsule-api that does not send it yet still builds).
- [ ] **Step 3:** `npx tsc --noEmit` passes. Commit `feat(tekton): build WordPress git images on the shared runtime`.

---

## Part D — `site`

### Task D1: Create wizard picks a PHP version

**Files:**
- Create: `src/app/features/create-content/pages/create-wordpress-capsule/wordpress-capsule-repo/select-php-version/select-php-version.component.{ts,html,scss}` + `.spec.ts`
- Delete: `…/select-wordpress-version/*`
- Modify: `src/app/data/capsule/models/capsule-type.ts` (replace `WordpressVersion` with `enum WordpressPhpVersion { v83='8.3', v84='8.4', v85='8.5' }` + `DEFAULT_WORDPRESS_PHP_VERSION = WordpressPhpVersion.v84`), `create-capsule-state.ts` (`wordpressVersion` → `phpVersion`), `base-create-capsule.component.ts:243-248` (read + validate `phpVersion` query param, fallback default), `wordpress-capsule-repo.component.{ts,html}` (selector shown for **both** deployment types; default-type step check no longer needs a version), `wordpress-capsule-deploy.component.ts:137-166` (`manifest.phpVersion`, no `version`; remove dead `onBuildCommandChanged`), `wordpress-cargo-manifest.dto.ts` (`phpVersion?: string`, drop `version`)

- [ ] **Step 1: Failing specs:** `select-php-version` renders three options in order 8.5, 8.4 ("Recommended"), 8.3 and emits the chosen value; `base-create-capsule` (or a pure helper it calls, e.g. `parseWordpressPhpVersion(param: string | null): WordpressPhpVersion` in `capsule-type.ts`) maps `'8.5'`→`'8.5'`, `'7.0'`/`null` → `'8.4'` (Review Focus 4).
- [ ] **Step 2:** `npm test` → fail. **Step 3:** Implement. Option copy: `"PHP 8.5"`, `"PHP 8.4 — Recommended"`, `"PHP 8.3"`, each with a php.net supported-versions link. "Default" deployment description: `"Deploy WordPress quickly and easily. You manage WordPress updates; we keep PHP patched."`
- [ ] **Step 4:** `npm test`, `npm run build:prod`, `npm run check:layers`, `check:cycles`, `check:imports`, `check:signals`, `npx tsc -p tsconfig.spec.json --noEmit` all pass. Commit `feat(wordpress): choose a PHP version when creating a WordPress capsule`.

### Task D2: Config card shows and changes the PHP version

**Files:** `src/app/data/capsule/models/runtime-config.ts:16-24`, `src/app/features/dashboard/capsules/components/wordpress-config/wordpress-config.component.{ts,html}` (+ spec if one exists, else create one for the save payload)

- [ ] **Step 1: Failing spec:** save sends `{phpVersion, database, healthCheck}` and **no** `version` key; a legacy capsule (`phpVersion: null`) shows `"Legacy image"` and saving without touching the select sends `phpVersion: null`.
- [ ] **Step 2:** Implement: `WordpressRuntimeConfig.phpVersion: WordpressPhpVersion | null`, `version` removed from the model. Select with the three versions (+ a disabled "Legacy image (keep current)" option when `null`). Helper text: default capsules `"Changing PHP redeploys your site. Check your plugins support the new version first."`; git capsules `"Changing PHP rebuilds your site from its repository."`
- [ ] **Step 3:** The Task D1 verification commands pass. Commit `feat(wordpress): change PHP version from the config page`.

---

## Rollout order (after merge)

1. PHP2Shell hotfix branches (already separate) — ship first.
2. A: build + smoke + push `php8.3-r1`, `php8.4-r1`, `php8.5-r1`; merge to `main`.
3. C: deploy the Tekton task (param defaults keep old capsule-api working).
4. B: deploy capsule-api (new capsules + PHP changes use runtimes; legacy capsules unchanged).
5. D: deploy site.
6. Announce, then run the job with `REDEPLOY_WORDPRESS_RETROFIT=true` dry run → canary IDs → all (+`INCLUDE_GIT`).
7. Follow-up: delete `legacy/`, the legacy image switch, archive `wordpress_git_docker`.

---

## Revisions (2026-10-22)

- **Tracks repinned** to the PHP2Shell-patched upstream digests (8.3.36 / 8.4.27 / 8.5.12). All three
  `php<minor>-r1` builds pass the 7-check smoke test with the real `MIN_PHP_VERSION` guards, and a
  volume seeded by the legacy 6.8 image moves onto `php8.3-r1` with `wp-config.php`, core and
  plugins byte-for-byte unchanged.
- **Task B5 replaced.** The redeploy job on `development` (#232, #235) no longer re-renders
  Deployments: it swaps only the container image with a conditional JSON patch
  (`K8sWorkloadService.replaceContainerImage`) and never touches git capsules
  (`redeployDecision`). Retrofit is rebuilt on top of that: `REDEPLOY_WORDPRESS_RETROFIT=true`
  adopts a legacy default capsule onto its runtime (`adopt` + save) and then swaps the image.
  **Git capsules are not retrofitted** — their next build already uses the 8.5 runtime — so
  `REDEPLOY_WORDPRESS_INCLUDE_GIT` no longer exists. `redeployDecision` recognises
  `wordpress-runtime` images so retrofitted capsules stay patchable on later tag bumps.
- **Node 24.** capsule-api and site moved to `node:24.22.1`; both feature branches are merged up
  to date with `development` and verified on that image.
- Rollout step 6 becomes: dry run with `RUN_REDEPLOY_WORDPRESS_CAPSULES=true` +
  `REDEPLOY_WORDPRESS_RETROFIT=true` → canary (`REDEPLOY_WORDPRESS_APPLY=true`,
  `REDEPLOY_WORDPRESS_CAPSULE_IDS`, `REDEPLOY_WORDPRESS_BATCH_SIZE=1`) → all → unset the `RUN_` var.

## Revisions (2026-10-23) — production hardening before the first test deployment

An audit of the runtime (security, performance/compatibility, integration, competitors) found
defects that would have shipped in `php8.x-r1`. All are fixed in the image; `REVISION` stays `1`
because nothing had been pushed yet (verify with `docker buildx imagetools inspect` before pushing —
if an `r1` exists, bump to `r2` and `WORDPRESS_RUNTIME_TAGS`).

Verified defects fixed:

- **Every pod stop hung 30s and was SIGKILLed**: the upstream image's `STOPSIGNAL` is `SIGQUIT`
  and `run.sh` trapped only TERM/INT. Now `STOPSIGNAL SIGTERM`, TERM/INT/QUIT all handled, and
  nginx/php-fpm get a graceful `QUIT` bounded by `SHUTDOWN_TIMEOUT_SECONDS`.
- **PHP-FPM listened on all interfaces**: `listen = 9000` (and the upstream `zz-docker.conf`
  overrode our pool file, which sorted before it). Now `listen = 127.0.0.1:9000` in `zzz-custom.conf`.
- **nginx logs went to files** inside the container (no rotation, invisible to Loki). Now stdout/stderr.
- **`add_header` inheritance** dropped every security header on static assets and, with
  `DEBUG_HEADERS=true`, on all PHP responses. Headers now use `more_set_headers` (headers-more module).
- **nginx started before php-fpm** (and before the first-boot core copy), so TCP readiness passed
  while requests got 502/404. php-fpm now starts first and nginx waits for it to listen.
- **Cache bypass regexes over-matched** (`~*s=` matched `?tags=`, `^/cart/?` matched `/cartoons/`).
  Anchored. Default cache key now uses `$forwarded_scheme`.
- **No cache purge**: added the Debian `ngx_cache_purge` module, a token-protected loopback purge
  location and a runtime mu-plugin (loaded through a pre-initialised hook from the prepend, no
  files on the volume) that purges on content changes, from the admin bar and via `wp cc cache purge`.
- **Page cache was off by default**; now `CACHE_TTL_SECONDS=60` by default (`0` disables).
- **FPM pool fixed at 12 children / OPcache 256M / `worker_processes auto`** regardless of the pod:
  now sized from the cgroup memory and CPU limits (`scripts/lib/runtime_env.sh`).
- **Rate limits too low for wp-admin/REST**: new defaults (public 300, wp-admin 120, REST 300 r/m)
  and a separate `login_routes` zone (30 r/m) for `wp-login.php`, `wp-comments-post.php`, `xmlrpc.php`.
- **HTTPS never signalled to PHP** and nginx redirects downgraded to `http://`: `HTTPS`/`REQUEST_SCHEME`/
  `SERVER_PORT` FastCGI params from `X-Forwarded-Proto`, `absolute_redirect off`, prepend sets `$_SERVER['HTTPS']`.
- **`DISABLE_WP_CRON` undefined** (page loads spawned a doomed loopback request), cron every 5 min:
  the prepend defines it; interval default 60s.
- **`MAX_UPLOAD_SIZE` unvalidated for PHP** (`64MB` → 64 bytes): shared validator for nginx and PHP.
- **Owner env values could crash-loop the pod**: `CSP_HEADER`/`HSTS_HEADER` validated,
  `NGINX_EXTRA_CONF` disabled on `nginx -t` failure, invalid `CACHE_*` fall back instead of exiting.
- **Deny list gaps** (`wp-config.old`, `*.sql`, plugin `changelog.txt`, drop-ins): blocked, as 404.
- **HSTS `includeSubDomains`** removed from the default (customer apex domains); `HSTS_HEADER` env.
  Deprecated `X-XSS-Protection` removed; CSP allows `wss:`.
- **Supply chain**: exporter binaries and WP-CLI verified by checksum, PhpRedis pinned (6.3.0),
  exporters run as `www-data`, production `php.ini`, ImageMagick PostScript coders closed.
- **Hardened WordPress defaults** via the prepend: `DISALLOW_FILE_EDIT`, `WP_MEMORY_LIMIT` 256M,
  `WP_MAX_MEMORY_LIMIT` 512M, `WP_REDIS_*` from env; owner-defined constants are never overridden.
- **WP-CLI** installed; `wp-metrics.php` counts all autoload values (WP ≥ 6.6) and reports the core version.
- `tests/smoke.sh` now installs WordPress with WP-CLI and checks: FPM on loopback, logs on stdout,
  headers on static assets, HSTS, redirect scheme, prepend constants, cache HIT, bypass rules,
  purge on publish and via CLI, login rate limit + log line, sensitive files, upload-size sync,
  metrics, FPM sizing log, graceful stop, plus the original install/volume/healthz/git checks.

Not changed here (follow-ups recorded in the audit write-up): capsule-api default probes
(`/healthz` HTTP), default resources (512Mi), seeding visible configs on create, a PodMonitor for
the exporters, retrofit of git capsules' `phpVersion`, unit tests for the retrofit job, pinning
`WP_RUNTIME_REF` in the Tekton task, SMTP, safe first boot, backups of the files volume.

Rollout order constraints confirmed by the audit: push `php8.x-r1` **before** deploying capsule-api
or the Tekton task; merge this branch to `main` and push **before** deploying the Tekton task
(it clones `codecaps/wordpress_docker` at `main` for `git/Dockerfile`); deploy the site only after
every cluster's capsule-api is upgraded (the new site omits `version`, which the old API requires).

## Revisions (2026-10-23, r2) — first live test on cc-proxmox

`php8.x-r1` was pushed and tested on the cc-proxmox cluster with the feature capsule-api. The legacy
→ runtime switch (6.8 capsule to PHP 8.4, `XMLRPC_ENABLED` adopted, existing volume untouched),
the config card, logs in the platform viewer, page cache HIT and all headers worked. One defect:
a **new** capsule's first boot copies WordPress core onto an NFS volume (~30-60s); with nginx
waiting for php-fpm, the default TCP startup probe (10s + 5×10s) killed the container mid-copy
once before the retry succeeded. `r2` starts nginx first and serves a 503 "starting up" page
(`runtime/html/starting.html`, `Retry-After: 5`, `/healthz` included) until FPM listens, so TCP
probes pass immediately and HTTP probes stay honest; the smoke test covers it (`starting-page`).
`REVISION=2` on every track; capsule-api `WORDPRESS_RUNTIME_TAGS` → `php8.x-r2`.

Platform findings from the live test (capsule-api, not the image):
- capsule-api never creates the WordPress database on the linked MySQL capsule (only the MySQL
  capsule's single default database `app` exists), so a second WordPress capsule on the same MySQL
  capsule cannot install. Jacques: capsule-api should check the database exists and create it.
- Two WordPress capsules can pick the same storage capsule; both mount the whole PVC at
  `/var/www/html` (no subPath), so they share one docroot. Use a per-capsule subPath or create a
  dedicated storage capsule per WordPress capsule.
- The Basic WordPress plan is 0.28GB / 7% CPU; the runtime sizes that to 2 FPM workers and php-fpm
  logs "reached pm.max_children" under probe + visitor traffic.
- On cc-proxmox every external visitor arrives as `192.168.1.1` (the test network's NAT), so the
  per-IP limits see one client; verify the real-IP chain on production clusters.

## Revisions (2026-10-23, r3) — pool floor and log noise

Measured on the Basic plan (267MiB): the whole pod idles at ~70MiB (nginx + exporters + FPM master
≈ 80MB RSS, a fresh WordPress worker 35–50MB). The r1/r2 formula gave that plan 2 workers, and two
slow requests (the WordPress installer calling api.wordpress.org took 41s) stalled the whole site.
r3 sizes the pool as `(memory − 96M − OPcache/4) / 56M`, clamped to 3–64 (Basic plan → 3, 512Mi →
6, 1Gi+ → 12 per CPU), and turns off php-fpm's own access log, which duplicated every nginx
request line in the platform log viewer. `REVISION=3`; capsule-api `WORDPRESS_RUNTIME_TAGS` → `php8.x-r3`.
