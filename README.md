# ubi-semaphore-ui

This repo is used to build and configure a container image running the Semaphore UI project using Red Hat’s Universal Base Image (UBI) as image base.

## How it works

`build/build_image.py` clones [semaphoreui/semaphore](https://github.com/semaphoreui/semaphore)
at a pinned tag and rewrites its server Dockerfile:

1. **Patch the build stage onto UBI** — swap the base image, translate `apk` to
   `dnf`, point the `task` installer somewhere on `PATH`.
2. **Delete upstream's Alpine runtime stage.**
3. **Render and append `build/templates/Dockerfile.ubi-minimal.j2`** as the new runtime stage.

The split is deliberate: upstream's build stage is the half that changes
between releases, so it carries as few patches as possible (currently three
hunks) and everything else we own lives in our own file. Upstream's
`go mod download`, `task deps`/`task build` and the tofu/terraform/terragrunt
fetches are left byte-identical.

Versions, the runtime package list, pip packages and the artifacts copied
from the build stage are declared in `CONFIG` at the top of
`build/build_image.py`. Only the runtime stage is a Jinja2 template; the
build stage stays a patch, so it cannot drift from upstream.

The template is appended, not prepended, because **the last stage in a
Dockerfile is the one that gets built**. Prepending it would produce a valid
Dockerfile that silently builds the *builder* stage instead.

```bash
python3 bootstrap.py                     # create .venv (uv + jinja2)
.venv/bin/python build/build_image.py    # rewrite the Dockerfile (idempotent)
# then run the docker build command it prints
```

The clone's Dockerfile is restored from git on every run, so re-running never
stacks edits.

## Why patch instead of fork

A patch that stops matching is the main hazard, and `sed` exits 0 when it
matches nothing. So every replacement is anchored on an exact block and the
script dies naming the block that failed, and a final `verify` re-checks the
result for leftover Alpine-isms, stage ordering, and that each artifact the
runtime copies is actually produced by the build stage.

If an upstream bump breaks a rule, the script tells you which one rather than
emitting a half-translated Dockerfile.

## Alpine to UBI

| Upstream (Alpine) | Here (UBI) | Note |
|---|---|---|
| `apk add` | `dnf` / `microdnf` | `dnf` in the build stage, `microdnf` in `ubi-minimal` |
| `libc-dev` | `glibc-devel` | |
| `py3-pip` | `python3.12-pip` | |
| `openssh-client-default` | `openssh-clients` | |
| `mysql-client` | `mysql` | `server-wrapper` shells out to `mysql` and `jq` |
| `gnupg` | `gnupg2` | |
| `tini` | fetched from GitHub | not packaged for UBI; EPEL-only, not worth a repo for a 24KB init |
| `adduser -D` | `useradd` | busybox vs shadow-utils |
| `echo $'..'`, `source` | `printf`, absolute paths | bashisms; `RUN` uses `/bin/sh` |

`curl` is deliberately absent from the runtime package list — `ubi-minimal`
ships `curl-minimal`, and requesting `curl` makes microdnf try to swap it out.

Group 0 rather than a private group is intentional: OpenShift runs containers
as an arbitrary uid in group 0, so the writable paths are `chown`ed `:0` and
left group-writable.

### The UBI build stage is about provenance, not linkage

Upstream builds with `CGO_ENABLED=0`, so the `semaphore` binary is fully static
(`ldd` reports "not a dynamic executable"). An Alpine builder would emit a
binary that runs on UBI just fine. The UBI build stage is here because a
UBI-based image is the point of the repo, not because musl would break the
binary.

The `go-toolset:9.8` tag, however, *is* load-bearing: `go.mod` requires
Go >= 1.26.4, and the 9.6 and 9.7 tags ship 1.24.6 and 1.25.9.

### No build toolchain in the runtime

Upstream installs `python3-dev build-base openssl-dev libffi-dev cargo`, pip
installs, then `apk del`s them. That exists because **musl cannot consume
PyPI's manylinux wheels**, so on Alpine pip compiles `cryptography`, `PyNaCl`
and `bcrypt` from source.

UBI is glibc and all three publish manylinux wheels for x86_64 and aarch64, so
pip fetches them prebuilt. Transliterating the install-then-remove dance does
not just waste a layer — it fails the build. `cargo` pulls in `rust`, and
removing `gcc`/`make` strips `/usr/bin/cc` from under the still-installed
`rust`, so the remove transaction is refused wholesale:

```
package rust-1.92.0 from @System requires /usr/bin/cc, but none of the
providers can be installed
```

## Image size

~1.37GB, essentially all runtime payload:

| Component | Size |
|---|---|
| ansible venv | 356MB (255MB of it `ansible_collections`) |
| tofu + terraform + terragrunt | 305MB |
| runtime packages | 195MB |
| `ubi-minimal` base | 110MB |
| `semaphore` binary | 50MB |

**A third build stage would not help.** A third stage pays off when the final
image carries build-time tooling to discard; here the builder is already
dropped, there are no compilers, and package/pip caches are cleaned within
their own layers. The levers that would actually move the number:

- **~255MB** — install `ansible-core` plus only the collections you use,
  instead of the full `ansible` distribution.
- **~100MB each** — drop whichever of tofu/terraform/terragrunt you do not use.

One size bug worth remembering: `chown`/`chmod` in a `RUN` after a `COPY`
rewrites the file into a new layer, which was duplicating the 50MB `semaphore`
binary. Ownership and mode are set on the `COPY` itself instead.

## Verifying a build

Exit code 0 is not evidence the image works. A useful smoke test:

```bash
docker run -d --name semtest -p 13000:3000 \
  -e SEMAPHORE_DB_DIALECT=sqlite -e SEMAPHORE_DB_PATH=/var/lib/semaphore \
  -e SEMAPHORE_ADMIN=admin -e SEMAPHORE_ADMIN_PASSWORD=changeme \
  -e SEMAPHORE_ADMIN_NAME=Admin -e SEMAPHORE_ADMIN_EMAIL=admin@example.com \
  <image>

curl -s localhost:13000/api/ping                       # pong
docker exec semtest cat /proc/1/cmdline | tr '\0' ' '  # /sbin/tini -- ...
docker exec semtest ansible -i localhost, -c local -m ping localhost
```

`SEMAPHORE_DB_DIALECT` accepts `mysql|postgres|sqlite`; `bolt` is deprecated.
Checking `tini` is PID 1 matters — zombie reaping for ansible is the only
reason it is in the image.

## Updating to a new upstream release

Bump `SEMAPHORE_REF` in `build/build_image.py` and re-run it. If upstream
changed a patched block the script stops and names it. Worth re-checking on a
bump:

- the Go version in `go.mod` against the `go-toolset` tag
- whether upstream's package list gained anything without a UBI equivalent
- `ANSIBLE_VERSION`, which also forms the venv path

## Known warnings

`SecretsUsedInArgOrEnv` on `ARG GH_TOKEN` comes from upstream and is only
reachable when building the pro module via `APP_BUILD_TYPE`. Left as upstream
has it; a BuildKit secret mount would be the fix if you build that variant,
since otherwise the token lands in image history.
