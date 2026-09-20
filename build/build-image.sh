#!/usr/bin/env bash
#
# Rewrites upstream Semaphore's server Dockerfile to build on UBI 9.
# See README.md for the design and the Alpine/UBI differences.

set -euo pipefail

# Exported: apply_versions reads these from perl's %ENV.
export UBI_VERSION=9.8
export PYTHON_VERSION=3.12
export NODEJS_VERSION=22
ANSIBLE_VERSION=13.5.0

# The tag is also the image version; upstream's Taskfile runs `git describe`.
SEMAPHORE_REPO=https://github.com/semaphoreui/semaphore.git
SEMAPHORE_REF=v2.19.14

BUILD_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CLONE_DIR="$BUILD_DIR/semaphore"
TEMPLATE="$BUILD_DIR/Dockerfile.ubi-minimal"
DOCKERFILE_REL=deployment/docker/server/Dockerfile
DOCKERFILE="$CLONE_DIR/$DOCKERFILE_REL"

IMAGE_TAG="ubi-semaphore-ui:${SEMAPHORE_REF#v}-ubi${UBI_VERSION}"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# Literal multi-line replace, or die: a rule that stops matching would exit 0.
replace_block() {
    local label="$1"
    export _FIND="$2" _REPL="$3"

    perl -0777 -i -pe '
        BEGIN { $find = $ENV{_FIND}; $repl = $ENV{_REPL} }
        $main::hits += s/\Q$find\E/$repl/g;
        END { exit($main::hits ? 0 : 9) }
    ' "$DOCKERFILE" || die "no match for '$label' - upstream $DOCKERFILE_REL changed since $SEMAPHORE_REF"

    printf '    patched: %s\n' "$label"
}

clone_semaphore() {
    step "Cloning $SEMAPHORE_REPO at $SEMAPHORE_REF"

    if [ -d "$CLONE_DIR/.git" ]; then
        git -C "$CLONE_DIR" fetch --depth 1 origin "refs/tags/$SEMAPHORE_REF:refs/tags/$SEMAPHORE_REF" --force
        git -C "$CLONE_DIR" checkout --quiet --force "$SEMAPHORE_REF"
        printf '    reusing existing clone\n'
    else
        git clone --depth 1 --branch "$SEMAPHORE_REF" "$SEMAPHORE_REPO" "$CLONE_DIR"
    fi

    [ -f "$DOCKERFILE" ] || die "$DOCKERFILE_REL not found in the clone"
    [ -f "$TEMPLATE" ] || die "$(basename "$TEMPLATE") not found"

    # Restore, so re-runs do not stack edits.
    git -C "$CLONE_DIR" checkout --quiet -- "$DOCKERFILE_REL" .dockerignore
}

# The Dockerfile sits inside the build context, so without this every rewrite
# invalidates `COPY .` and re-runs the Go and npm builds.
exclude_dockerfile_from_context() {
    step "Excluding $DOCKERFILE_REL from the build context"

    printf '%s\n' "$DOCKERFILE_REL" >> "$CLONE_DIR/.dockerignore"
}

# The 9.8 tag is required: go.mod needs Go >= 1.26.4, 9.6/9.7 ship older.
build_on_ubi() {
    step "Rebasing upstream's build stage onto UBI $UBI_VERSION"

    replace_block 'builder FROM' \
'FROM --platform=$BUILDPLATFORM golang:1.26-alpine3.24 as builder' \
'ARG UBI_VERSION=@UBI_VERSION@

FROM registry.access.redhat.com/ubi9/go-toolset:${UBI_VERSION} AS builder

USER 0

# go-toolset defaults GOPATH to /opt/app-root; upstream uses /go.
ENV GOPATH=/go \
    GOCACHE=/root/.cache/go-build \
    HOME=/root
ENV PATH="/go/bin:${PATH}"'

    # Upstream's installer defaults to ./bin, which is not on PATH here.
    replace_block 'task installer' \
'RUN curl -sL https://taskfile.dev/install.sh | sh' \
'RUN curl -fsSL https://taskfile.dev/install.sh | sh -s -- -b /usr/local/bin'
}

use_ubi_package_manager() {
    step "Translating the build stage's apk call to dnf"

    # nodejs is a module stream in RHEL 9; pin it or the default stream decides.
    replace_block 'builder apk' \
'RUN apk add --no-cache -U \
    libc-dev curl nodejs npm git gcc zip unzip tar' \
'RUN dnf -y module enable "nodejs:@NODEJS_VERSION@" && \
    dnf -y install --nodocs --setopt=install_weak_deps=0 \
        glibc-devel nodejs npm git gcc zip unzip tar wget && \
    dnf clean all && rm -rf /var/cache/dnf'
}

# Replaced wholesale by the template, so deleted rather than ported.
drop_upstream_runtime() {
    step "Dropping upstream's Alpine runtime stage"

    grep -q '^FROM alpine:3\.21$' "$DOCKERFILE" || die "runtime FROM not found - upstream $DOCKERFILE_REL changed since $SEMAPHORE_REF"

    # \n not $: perl reads `$.` in a pattern as the line-number variable.
    perl -0777 -i -pe 's/^FROM alpine:3\.21\n.*\z//ms' "$DOCKERFILE"

    ! grep -q '^FROM alpine:' "$DOCKERFILE" || die 'runtime stage was not removed'
    printf '    dropped\n'
}

# Appended, not prepended: the last stage is the one that gets built.
append_runtime_stage() {
    step "Appending $(basename "$TEMPLATE") as the runtime stage"

    cat "$TEMPLATE" >> "$DOCKERFILE"
}

# Dies rather than expanding an unset name to "", which fails only mid-build.
apply_versions() {
    perl -i -pe '
        s{\@([A-Z_]+)\@}{
            my $v = $ENV{$1};
            die "placeholder \@$1\@ has no value in the environment\n"
                unless defined $v && length $v;
            $v;
        }ge;
    ' "$DOCKERFILE" || die 'version substitution failed'
}

verify() {
    step "Verifying the result"

    local leftovers
    # \b on libc-dev, else it matches gLIBC-DEVel; comments may say "Alpine".
    leftovers=$(grep -nEi '\bapk\b|alpine|musl|\badduser\b|(^|&&)[[:space:]]*source\b|\bpy3-|\blibc-dev\b' "$DOCKERFILE" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [ -z "$leftovers" ] || die "untranslated Alpine references remain:
$leftovers"

    grep -q '^FROM registry.access.redhat.com/ubi9/go-toolset:.* AS builder$' "$DOCKERFILE" || die 'build stage missing'

    local last_from
    last_from=$(grep -E '^FROM ' "$DOCKERFILE" | tail -1)
    case "$last_from" in
        FROM\ registry.access.redhat.com/ubi9/ubi-minimal:*) ;;
        *) die "last stage must be the ubi-minimal runtime, got: $last_from" ;;
    esac

    # Every artifact the runtime copies must exist in the build stage.
    local src
    for src in /go/src/semaphore/bin/semaphore \
               /go/src/semaphore/deployment/docker/server/server-wrapper \
               /tmp/tofu /tmp/terraform /tmp/terragrunt; do
        grep -qE "^COPY --from=builder.* $src " "$DOCKERFILE" || die "runtime does not copy $src"
    done

    # An empty substitution also removes the markers, so assert the values.
    grep -q "ARG UBI_VERSION=$UBI_VERSION\$" "$DOCKERFILE" || die 'UBI_VERSION did not substitute'
    grep -q "ARG PYTHON_VERSION=$PYTHON_VERSION\$" "$DOCKERFILE" || die 'PYTHON_VERSION did not substitute'
    grep -q "nodejs:$NODEJS_VERSION" "$DOCKERFILE" || die 'NODEJS_VERSION did not substitute'

    printf '    clean\n'
}

clone_semaphore
build_on_ubi
use_ubi_package_manager
drop_upstream_runtime
append_runtime_stage
apply_versions
exclude_dockerfile_from_context
verify

step "Done - $DOCKERFILE_REL is now UBI $UBI_VERSION"
cat <<EOF

Review:
    git -C "$CLONE_DIR" diff -- $DOCKERFILE_REL

Build (BuildKit required for TARGETARCH and the cache mounts):
    DOCKER_BUILDKIT=1 docker build \\
        -f "$DOCKERFILE" \\
        -t "$IMAGE_TAG" \\
        --build-arg ANSIBLE_VERSION=$ANSIBLE_VERSION \\
        "$CLONE_DIR"
EOF
