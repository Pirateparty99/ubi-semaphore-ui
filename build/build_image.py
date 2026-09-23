#!/usr/bin/env python3
"""Rewrite upstream Semaphore's server Dockerfile to build on UBI 9.

See README.md for the design and the Alpine/UBI differences.
"""

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml
import deps
from jinja2 import Environment, FileSystemLoader, StrictUndefined

BUILD_DIR = Path(__file__).resolve().parent
CLONE_DIR = BUILD_DIR / "semaphore"
TEMPLATE_DIR = BUILD_DIR / "templates"
RUNTIME_TEMPLATE = "Dockerfile.ubi-minimal.j2"
DOCKERFILE_REL = "deployment/docker/server/Dockerfile"

# The tag is also the image version; upstream's Taskfile runs `git describe`.
SEMAPHORE_REPO = "https://github.com/semaphoreui/semaphore.git"
SEMAPHORE_REF = "v2.19.14"

# ansible_version is ansible-core's: it names the venv path, and core is what
# the deps stage installs. Package lists come from deps/.
with open(vars.yaml, r) as var_file:
    CONFIG = { yaml.safe_load(var_file) **deps.load() }

UPSTREAM_RUNTIME_FROM = "FROM alpine:3.21"


class BuildError(Exception):
    """Raised when upstream no longer matches what a patch expects."""


@dataclass(frozen=True)
class Patch:
    label: str
    find: str
    replace: str


# Upstream's build stage is patched, not replaced, so their go/npm/IaC steps
# stay byte-identical and version bumps stay cheap.
PATCHES = [
    Patch(
        "builder FROM",
        "FROM --platform=$BUILDPLATFORM golang:1.26-alpine3.24 as builder",
        """ARG UBI_VERSION={{ ubi_version }}

FROM registry.access.redhat.com/ubi9/go-toolset:${UBI_VERSION} AS builder

USER 0

# go-toolset defaults GOPATH to /opt/app-root; upstream uses /go.
ENV GOPATH=/go \\
    GOCACHE=/root/.cache/go-build \\
    HOME=/root
ENV PATH="/go/bin:${PATH}\"""",
    ),
    Patch(
        "builder packages",
        "RUN apk add --no-cache -U \\\n    libc-dev curl nodejs npm git gcc zip unzip tar",
        """RUN dnf -y module enable "nodejs:{{ nodejs_version }}" && \\
    dnf -y install --nodocs --setopt=install_weak_deps=0 \\
        glibc-devel nodejs npm git gcc zip unzip tar wget && \\
    dnf clean all && rm -rf /var/cache/dnf""",
    ),
    # Upstream's installer defaults to ./bin, which is not on PATH here.
    Patch(
        "task installer",
        "RUN curl -sL https://taskfile.dev/install.sh | sh",
        "RUN curl -fsSL https://taskfile.dev/install.sh | sh -s -- -b /usr/local/bin",
    ),
]


def step(message: str) -> None:
    """Progress goes to stderr, so --print emits only the Dockerfile."""
    print(f"\n==> {message}", file=sys.stderr)


def run(*cmd: str, cwd: Path | None = None) -> None:
    subprocess.run(cmd, cwd=cwd, check=True)


def wrap_packages(items: list[str], per_line: int = 9, indent: str = " " * 8) -> str:
    """Join into backslash-continued lines, so package lists stay readable."""
    lines = [" ".join(items[i:i + per_line]) for i in range(0, len(items), per_line)]
    return (" \\\n" + indent).join(lines)


def render(source: str, **extra: object) -> str:
    env = Environment(
        loader=FileSystemLoader(TEMPLATE_DIR),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    env.filters["wrap"] = wrap_packages
    context = {**CONFIG, **extra}
    if source.endswith(".j2"):
        return env.get_template(source).render(context)
    return env.from_string(source).render(context)


def clone_semaphore(dockerfile: Path) -> None:
    step(f"Cloning {SEMAPHORE_REPO} at {SEMAPHORE_REF}")

    if (CLONE_DIR / ".git").is_dir():
        run("git", "fetch", "--depth", "1", "origin",
            f"refs/tags/{SEMAPHORE_REF}:refs/tags/{SEMAPHORE_REF}", "--force",
            cwd=CLONE_DIR)
        run("git", "checkout", "--quiet", "--force", SEMAPHORE_REF, cwd=CLONE_DIR)
        print("    reusing existing clone", file=sys.stderr)
    else:
        run("git", "clone", "--depth", "1", "--branch", SEMAPHORE_REF,
            SEMAPHORE_REPO, str(CLONE_DIR))

    if not dockerfile.is_file():
        raise BuildError(f"{DOCKERFILE_REL} not found in the clone")

    # Restore, so re-runs do not stack edits.
    run("git", "checkout", "--quiet", "--", DOCKERFILE_REL, ".dockerignore",
        cwd=CLONE_DIR)


def apply_patches(text: str) -> str:
    """Apply each patch or raise: a rule that silently stops matching is the risk."""
    step("Patching upstream's build stage onto UBI")

    for patch in PATCHES:
        if patch.find not in text:
            raise BuildError(
                f"no match for {patch.label!r} - upstream {DOCKERFILE_REL} "
                f"changed since {SEMAPHORE_REF}"
            )
        text = text.replace(patch.find, render(patch.replace))
        print(f"    patched: {patch.label}", file=sys.stderr)

    return text


def drop_upstream_runtime(text: str) -> str:
    """Replaced wholesale by the template, so deleted rather than ported."""
    step("Dropping upstream's Alpine runtime stage")

    index = text.find(f"\n{UPSTREAM_RUNTIME_FROM}\n")
    if index == -1:
        raise BuildError(
            f"runtime FROM not found - upstream {DOCKERFILE_REL} changed "
            f"since {SEMAPHORE_REF}"
        )

    print("    dropped", file=sys.stderr)
    return text[: index + 1]


def append_runtime_stage(text: str) -> str:
    """Appended, not prepended: the last stage is the one that gets built."""
    step(f"Appending {RUNTIME_TEMPLATE} as the runtime stage")

    return text + render(RUNTIME_TEMPLATE)


def exclude_dockerfile_from_context() -> None:
    """The Dockerfile sits in the build context; without this every rewrite
    invalidates `COPY .` and re-runs the Go and npm builds."""
    step(f"Excluding {DOCKERFILE_REL} from the build context")

    dockerignore = CLONE_DIR / ".dockerignore"
    with dockerignore.open("a", encoding="utf-8") as handle:
        handle.write(f"{DOCKERFILE_REL}\n")


def verify(text: str) -> None:
    step("Verifying the result")

    # Comment lines may mention Alpine legitimately, to explain the port.
    alpineisms = re.compile(
        r"\bapk\b|alpine|musl|\badduser\b|(?:^|&&)\s*source\b|\bpy3-|\blibc-dev\b",
        re.IGNORECASE,
    )
    leftovers = [
        f"{number}:{line}"
        for number, line in enumerate(text.splitlines(), 1)
        if not line.lstrip().startswith("#") and alpineisms.search(line)
    ]
    if leftovers:
        raise BuildError("untranslated Alpine references remain:\n" + "\n".join(leftovers))

    if not re.search(r"^FROM registry\.access\.redhat\.com/ubi9/go-toolset:.* AS builder$",
                     text, re.MULTILINE):
        raise BuildError("build stage missing")

    froms = re.findall(r"^FROM .*$", text, re.MULTILINE)
    if not froms or not froms[-1].startswith("FROM registry.access.redhat.com/ubi9/ubi-minimal:"):
        raise BuildError(f"last stage must be the ubi-minimal runtime, got: {froms[-1:]}")

    if not any(line.endswith(" AS deps") for line in froms):
        raise BuildError("deps stage missing")
    if "COPY --from=deps" not in text:
        raise BuildError("runtime does not copy the venv from deps")

    # Every artifact the runtime copies must exist in the build stage.
    for artifact in CONFIG["builder_artifacts"]:
        if f"COPY --from=builder {artifact['flags']}{artifact['src']} " not in text:
            raise BuildError(f"runtime does not copy {artifact['src']}")

    print("    clean", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--print", action="store_true",
                        help="write the Dockerfile to stdout instead of the clone")
    args = parser.parse_args()

    dockerfile = CLONE_DIR / DOCKERFILE_REL

    try:
        clone_semaphore(dockerfile)
        text = dockerfile.read_text(encoding="utf-8")
        text = apply_patches(text)
        text = drop_upstream_runtime(text)
        text = append_runtime_stage(text)
        verify(text)
    except BuildError as error:
        print(f"\nerror: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"\nerror: command failed: {' '.join(error.cmd)}", file=sys.stderr)
        return 1

    if args.print:
        sys.stdout.write(text)
        return 0

    dockerfile.write_text(text, encoding="utf-8")
    exclude_dockerfile_from_context()

    image_tag = f"ubi-semaphore-ui:{SEMAPHORE_REF.lstrip('v')}-ubi{CONFIG['ubi_version']}"
    step(f"Done - {DOCKERFILE_REL} is now UBI {CONFIG['ubi_version']}")
    print(f"""
Review:
    git -C "{CLONE_DIR}" diff -- {DOCKERFILE_REL}

Build (BuildKit required for TARGETARCH and the cache mounts):
    DOCKER_BUILDKIT=1 docker build \\
        -f "{dockerfile}" \\
        -t "{image_tag}" \\
        --build-arg ANSIBLE_VERSION={CONFIG['ansible_version']} \\
        "{CLONE_DIR}"
""")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
