"""Dependency loaders: each subpackage declares one kind of dependency."""

from . import galaxy, pip, terraform

# Copied from the build stage regardless of which IaC tools are enabled.
SEMAPHORE_ARTIFACTS = [
    {"src": "/go/src/semaphore/deployment/docker/server/server-wrapper",
     "dest": "/usr/local/bin/", "flags": "--chown=1001:0 --chmod=755 "},
    {"src": "/go/src/semaphore/bin/semaphore",
     "dest": "/usr/local/bin/", "flags": "--chown=1001:0 --chmod=755 "},
]


def load() -> dict[str, object]:
    return {
        "pip_packages": pip.load(),
        "galaxy_collections": galaxy.load(),
        "builder_artifacts": SEMAPHORE_ARTIFACTS + terraform.load(),
    }
