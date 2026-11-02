# Git capsule image

Git capsules run on the same PHP runtime as default capsules (the repo root `Dockerfile`), with
the capsule's WordPress repo copied into the docroot. This folder is that layer.

## Build contract

The Tekton build task (`infra-cluster-pipelines`, `build-wordpress-image-from-git-task`) relies on:

- **Context:** this `git/` folder.
- **Source:** the user's repo cloned to `git/wp-html` (its `.git` is excluded by `.dockerignore`).
- **Base:** `--build-arg RUNTIME_IMAGE=<full image ref>`, an immutable runtime tag such as
  `europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php8.5-r1`. There is no default;
  capsule-api picks the ref from the capsule's PHP version.

```bash
git clone <repo> git/wp-html
docker buildx build git --platform linux/amd64 \
  --build-arg RUNTIME_IMAGE=europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php8.5-r1
```

Everything else (nginx, PHP-FPM, metrics, cron trigger, env vars) comes from the runtime; see the
repo `readme.md`. Git capsules that need more FPM workers set `WORDPRESS_FPM_CONF`.
