# ubi-semaphore-ui

This repo is used to build and configure a container image running the Semaphore UI project using Red Hat’s Universal Base Image (UBI) as image base.

## How it works

`build/build_image.py` clones [semaphoreui/semaphore](https://github.com/semaphoreui/semaphore)
at a pinned tag and rewrites its server Dockerfile:

1. **Patch the build stage onto UBI** — swap the base image, translate `apk` to
   `dnf`, point the `task` installer somewhere on `PATH`.
2. **Delete upstream's Alpine runtime stage.**
3. **Render and append `templates/Dockerfile.ubi-minimal.j2`**, which
   supplies a `deps` stage and the final runtime stage.

The split is deliberate: upstream's build stage is the half that changes
between releases, so it carries as few patches as possible (currently three
hunks) and everything else we own lives in our own file. Upstream's
`go mod download`, `task deps`/`task build` and the tofu/terraform/terragrunt
fetches are left byte-identical.

`vars.yaml` is the single configuration file. It holds four sections:

| Section | Holds |
|---|---|
| `image` | versions and the runtime package list, rendered into the Dockerfile |
| `semaphore` | upstream repo and tag |
| `paths` | clone directory, template directory and names, relative to `build/` |
| `upstream` | the `find`/`replace` patch rules and the runtime `FROM` anchor |

Only `deps/` sits outside it, holding the dependency lists. Nothing else
in `build_image.py` is tunable — the script derives its own location and reads
everything else from `vars.yaml`.

The `upstream.patches` entries are the coupling to semaphore's own Dockerfile:
each `find` must match its text exactly, and the `replace` blocks are rendered
as Jinja2, so `image` variables work inside them. If upstream renames something
the script stops and names the patch that no longer matches.

Quote every version in `vars.yaml`. Unquoted, YAML parses `3.10` as the float
`3.1`, which would render as `python3.1`; the loader rejects non-string
versions rather than let that reach a build.

The template is appended, not prepended, because **the last stage in a
Dockerfile is the one that gets built**. Prepending it would produce a valid
Dockerfile that silently builds the *builder* stage instead.

```bash
python3 bootstrap.py                     # install uv into .tools, create .venv
.venv/bin/python build/build_image.py    # rewrite the Dockerfile (idempotent)
# then run the docker build command it prints
```

The clone's Dockerfile is restored from git on every run, so re-running never
stacks edits.

`bootstrap.py` runs in two phases: it installs the build tooling (uv) and
then uses uv to create `.venv` with the build dependencies. uv lands in
`.tools/` rather than `.venv/`, since it is what *creates* the venv. A host
uv is reused when present; `--force-uv-install` forces the isolated copy.

Both directories are disposable — deleting them and re-running is the
supported reset. A system `pip install uv` is not used because this host, like most Debian/Ubuntu ones, is PEP 668 externally-managed.

## Why patch instead of fork

A patch that stops matching is the main hazard, and `sed` exits 0 when it
matches nothing. So every replacement is anchored on an exact block and the
script dies naming the block that failed, and a final `verify` re-checks the
result for leftover Alpine-isms, stage ordering, and that each artifact the
runtime copies is actually produced by the build stage.

If an upstream bump breaks a rule, the script tells you which one rather than
emitting a half-translated Dockerfile.

## Dependencies

Declared under `deps/`, one subdirectory per kind, each pairing a
requirements file with the loader that reads it:

| Directory | Declares | Read by |
|---|---|---|
| `deps/pip/requirements.txt` | Python packages in the ansible venv | `deps/pip` |
| `deps/galaxy/requirements.yml` | Ansible collections | `deps/galaxy` |
| `deps/terraform/tools.toml` | Which IaC binaries reach the image | `deps/terraform` |

The loaders feed the Jinja2 context, so the Dockerfile renders these inline
rather than `COPY`ing requirement files. That matters: anything added to the
build context invalidates upstream's `COPY . /go/src/semaphore`, so a
dependency change would otherwise force a full Go and npm rebuild.

A separate `deps` stage installs them and the runtime copies the finished venv,
which decouples dependency installs from the application build in both
directions — editing Go code does not reinstall ansible, and editing
requirements does not recompile Go.

### ansible-core, not ansible

The `ansible` distribution bundles ~49 collection namespaces totalling 255MB,
most of them vendor-specific (`fortinet/fortimanager` 28MB, `cisco/dnac` 23MB,
`fortinet/fortios` 21MB). The image installs `ansible-core` and only the
collections listed in `deps/galaxy/requirements.yml`.

**This is a coverage tradeoff, not a free win.** A playbook using a collection
that is not declared will fail with a module-not-found error where the full
distribution would have worked. `deps/galaxy/requirements.yml` is the knob —
add what you use. Likewise `deps/terraform/tools.toml`: upstream's build stage
fetches tofu, terraform and terragrunt regardless, but only the enabled ones
are copied into the image, at roughly 100MB each.

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

~1.04GB, down from 1.3GB when the full `ansible` distribution was installed:

| Component | Size |
|---|---|
| ansible venv | 125MB (50MB of it `ansible_collections`, 9 namespaces) |
| tofu + terraform + terragrunt | 305MB |
| runtime packages | 195MB |
| `ubi-minimal` base | 110MB |
| `semaphore` binary | 50MB |

The venv was 335MB before `ansible-core` replaced the full distribution
(255MB of collections across 49 namespaces).

The `deps` stage exists for caching, not for shrinking: the builder is already
discarded, there are no compilers, and package caches are cleaned within their
own layers, so there is no build-time tooling left for another stage to strip.
What it buys is independence — dependency installs no longer share a cache key
with the Go and npm build.

The remaining size lever is `deps/terraform/tools.toml`: roughly 100MB per IaC
binary you do not need.

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

Bump `semaphore.ref` in `vars.yaml` and re-run the build script. If upstream
changed a patched block the script stops and names it. Worth re-checking on a
bump:

- the Go version in `go.mod` against the `go-toolset` tag
- whether upstream's package list gained anything without a UBI equivalent
- `image.ansible_version`, which also forms the venv path

## Known warnings

`SecretsUsedInArgOrEnv` on `ARG GH_TOKEN` comes from upstream and is only
reachable when building the pro module via `APP_BUILD_TYPE`. Left as upstream
has it; a BuildKit secret mount would be the fix if you build that variant,
since otherwise the token lands in image history.
