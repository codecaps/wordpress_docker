#!/usr/bin/env bash
# Host-side helper for the push scripts (push.sh, legacy/docker_push.sh); not part of any image.
#
# registry_tag_state <ref>: whether an image tag may be pushed without overwriting anything.
#   0  the registry answered that the tag does not exist
#   1  the tag exists (an immutable tag must never be pushed twice)
#   2  the registry could not be asked (expired login, credential helper failure, network): the
#      answer is unknown, so the caller must not push. Treating every inspect failure as "absent"
#      would let an expired login overwrite a tag that is already deployed.
# Prints why on stderr for 2.
registry_tag_state() {
    local ref="$1" out
    if out="$(docker buildx imagetools inspect "$ref" 2>&1)"; then
        return 1
    fi
    # buildx reports a missing tag as exactly "ERROR: <ref>: not found" (the ref has no spaces),
    # which no credential, DNS or TLS error matches ("executable file not found in $PATH" does not).
    if grep -qE '^ERROR: [^ ]+: not found$' <<<"$out"; then
        return 0
    fi
    echo "could not check whether ${ref} already exists in the registry (log in again and retry):" >&2
    printf '%s\n' "$out" | tail -n 3 >&2
    return 2
}
