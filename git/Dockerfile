# A git capsule's image: the shared PHP runtime plus the capsule's WordPress repo.
# Built by the Tekton build task with this folder as the context, the repo cloned to ./wp-html
# and --build-arg RUNTIME_IMAGE=<immutable runtime image ref> (see README.md).
# No default runtime: a build that does not name one must fail.
ARG RUNTIME_IMAGE
FROM ${RUNTIME_IMAGE}

COPY --chown=www-data:www-data ./wp-html /var/www/html
