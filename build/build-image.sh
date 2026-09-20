#!/usr/bin/env bash
#
# Rewrites upstream Semaphore's server Dockerfile from Alpine to UBI 9:
#   1. clone the semaphore repo
#   2. drop upstream's builder stage, rebase the runtime on the UBI Python image
#   3. replace musl-only steps with glibc equivalents
#   4. translate apk to dnf
#   5. cat Dockerfile.ubi-minimal on the front as the new build stage
#
# Patches the clone in place, restoring from git each run, so it is idempotent.

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

# Literal multi-line replace, or die. Silence is the hazard here: a patch that
# stops matching after an upstream edit would otherwise exit 0.
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

    git -C "$CLONE_DIR" checkout --quiet -- "$DOCKERFILE_REL"
}

# The template supplies the build stage, so upstream's is deleted rather than
# translated. python-312 already ships python 3.12 and pip, so the runtime
# installs neither.
use_ubi_python_base() {
    step "Rebasing runtime onto UBI Python, dropping upstream's build stage"

    perl -0777 -i -pe 's/\A.*?(?=^FROM alpine:3\.21$)//ms' "$DOCKERFILE"
    grep -q '^FROM alpine:3\.21$' "$DOCKERFILE" || die "runtime FROM not found - upstream $DOCKERFILE_REL changed since $SEMAPHORE_REF"
    printf '    stripped: upstream build stage\n'

    replace_block 'runtime FROM' \
'FROM alpine:3.21' \
'FROM registry.access.redhat.com/ubi9/python-312:${UBI_VERSION}

ARG UBI_VERSION
ARG PYTHON_VERSION=@PYTHON_VERSION@

USER 0'
}

use_glibc() {
    step "Replacing musl-specific steps with glibc equivalents"

    # echo $'..' is a bashism; RUN uses /bin/sh.
    replace_block 'ssh_config bashism' \
"RUN echo \$'Host *\\n  StrictHostKeyChecking no\\n  UserKnownHostsFile /dev/null' > /etc/ssh/ssh_config.d/semaphore.conf" \
'RUN mkdir -p /etc/ssh/ssh_config.d && \
    printf '"'"'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n'"'"' \
      > /etc/ssh/ssh_config.d/semaphore.conf'

    # musl cannot use manylinux wheels, so Alpine compiles cryptography, PyNaCl
    # and bcrypt and needs gcc/cargo. glibc gets them prebuilt. Do not restore
    # the toolchain: cargo pulls in rust, and the matching `apk del` becomes a
    # dnf remove that fails, since dropping gcc strips /usr/bin/cc from under
    # the still-installed rust.
    replace_block 'ansible venv toolchain' \
'RUN apk add --no-cache -U python3-dev build-base openssl-dev libffi-dev cargo && \
     mkdir -p ${ANSIBLE_VENV_PATH} && \
     python3 -m venv ${ANSIBLE_VENV_PATH} --system-site-packages && \
     source ${ANSIBLE_VENV_PATH}/bin/activate && \
     pip3 install --upgrade pip ansible==${ANSIBLE_VERSION} boto3 botocore requests pywinrm passlib paramiko && \
     apk del python3-dev build-base openssl-dev libffi-dev cargo && \
     rm -rf /var/cache/apk/* && \
     find ${ANSIBLE_VENV_PATH} -iname __pycache__ | xargs rm -rf && \
     chown -R semaphore:0 /opt/semaphore' \
'# No compilers: glibc gets prebuilt wheels. See build-image.sh before adding
# any back.
RUN "python${PYTHON_VERSION}" -m venv "${ANSIBLE_VENV_PATH}" --system-site-packages && \
    "${ANSIBLE_VENV_PATH}/bin/pip" install --no-cache-dir --upgrade pip && \
    "${ANSIBLE_VENV_PATH}/bin/pip" install --no-cache-dir \
        "ansible==${ANSIBLE_VERSION}" boto3 botocore requests pywinrm passlib paramiko && \
    find "${ANSIBLE_VENV_PATH}" -type d -name __pycache__ -prune -exec rm -rf {} + && \
    chown -R semaphore:0 /opt/semaphore && \
    chmod -R g=u /opt/semaphore'

    replace_block 'tini COPY' \
'COPY --from=builder /tmp/terragrunt /usr/local/bin/' \
'COPY --from=builder /tmp/terragrunt /usr/local/bin/
COPY --from=builder /tmp/tini /sbin/tini'
}

use_ubi_package_manager() {
    step "Translating apk to dnf"

    # Renames: openssh-client-default -> openssh-clients, mysql-client ->
    # mysql, gnupg -> gnupg2. python3/py3-pip are dropped - the base has them.
    #
    # -o on useradd because the base image already holds uid 1001 as "default";
    # semaphore becomes a second name for it, which USER 1001 and the chowns
    # below both expect.
    #
    # Group 0, not a private group: OpenShift runs an arbitrary uid in group 0.
    replace_block 'runtime apk' \
'RUN apk add --no-cache -U \
    bash curl git gnupg mysql-client openssh-client-default python3 py3-pip rsync sshpass tar tini tzdata unzip wget zip jq && \
    rm -rf /var/cache/apk/* && \
    adduser -D -u 1001 -G root semaphore && \
    mkdir -p /tmp/semaphore && \
    mkdir -p /etc/semaphore && \
    mkdir -p /var/lib/semaphore && \
    mkdir -p /opt/semaphore && \
    chown -R semaphore:0 /tmp/semaphore && \
    chown -R semaphore:0 /etc/semaphore && \
    chown -R semaphore:0 /var/lib/semaphore && \
    chown -R semaphore:0 /opt/semaphore && \
    find /usr/lib/python* -iname __pycache__ | xargs rm -rf' \
'RUN dnf install -y --nodocs --setopt=install_weak_deps=0 \
        bash git gnupg2 mysql openssh-clients rsync sshpass tar tzdata \
        unzip wget zip jq shadow-utils findutils glibc-langpack-en && \
    dnf clean all && rm -rf /var/cache/dnf && \
    useradd -u 1001 -o -g 0 -m -d /home/semaphore -s /bin/bash semaphore && \
    mkdir -p /tmp/semaphore /etc/semaphore /var/lib/semaphore /opt/semaphore && \
    chown -R semaphore:0 /tmp/semaphore /etc/semaphore /var/lib/semaphore /opt/semaphore && \
    chmod -R g=u /tmp/semaphore /etc/semaphore /var/lib/semaphore /opt/semaphore && \
    find /usr/lib /usr/lib64 -type d -name __pycache__ -prune -exec rm -rf {} +'

    replace_block 'locale env' \
'ENV PATH="$ANSIBLE_VENV_PATH/bin:$PATH"' \
'ENV PATH="$ANSIBLE_VENV_PATH/bin:$PATH"
ENV LANG=en_US.UTF-8'
}

# Template first: the last stage in a Dockerfile is the one that gets built, so
# appending it would silently make the builder the final image. A temp file is
# required - `cat a b > b` truncates b before reading it.
prepend_build_stage() {
    step "Prepending $(basename "$TEMPLATE") as the build stage"

    local tmp
    tmp=$(mktemp)
    cat "$TEMPLATE" "$DOCKERFILE" > "$tmp"
    mv "$tmp" "$DOCKERFILE"
}

# Dies rather than expanding an unset name to "", which would yield a valid
# Dockerfile pulling `go-toolset:` and failing only mid-build.
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
    # \b on libc-dev: without it the pattern matches gLIBC-DEVel. Comment lines
    # are dropped - they mention Alpine legitimately, to explain the port.
    leftovers=$(grep -nEi '\bapk\b|alpine|musl|\badduser\b|(^|&&)[[:space:]]*source\b|\bpy3-|\blibc-dev\b' "$DOCKERFILE" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [ -z "$leftovers" ] || die "untranslated Alpine references remain:
$leftovers"

    grep -q '^FROM registry.access.redhat.com/ubi9/go-toolset:.* AS builder$' "$DOCKERFILE" || die 'build stage missing'
    grep -q '^FROM registry.access.redhat.com/ubi9/python-312:' "$DOCKERFILE" || die 'runtime is not on the UBI Python image'

    # The build stage must precede the runtime, or the builder becomes the image.
    local builder_line runtime_line
    builder_line=$(grep -n ' AS builder$' "$DOCKERFILE" | head -1 | cut -d: -f1)
    runtime_line=$(grep -n '^FROM registry.access.redhat.com/ubi9/python-312:' "$DOCKERFILE" | head -1 | cut -d: -f1)
    [ "$builder_line" -lt "$runtime_line" ] || die "build stage (line $builder_line) must come before the runtime (line $runtime_line)"

    # Assert the values landed; an empty substitution also removes the markers.
    grep -q "ARG UBI_VERSION=$UBI_VERSION\$" "$DOCKERFILE" || die 'UBI_VERSION did not substitute'
    grep -q "ARG PYTHON_VERSION=$PYTHON_VERSION\$" "$DOCKERFILE" || die 'PYTHON_VERSION did not substitute'
    grep -q "nodejs:$NODEJS_VERSION" "$DOCKERFILE" || die 'NODEJS_VERSION did not substitute'

    printf '    clean\n'
}

clone_semaphore
use_ubi_python_base
use_glibc
use_ubi_package_manager
prepend_build_stage
apply_versions
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
