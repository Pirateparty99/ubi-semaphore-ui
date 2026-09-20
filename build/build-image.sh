#!/bin/bash

UBI_VERSION=9.8
PYTHON_VERSION=3.12


git clone https://github.com/semaphoreui/semaphore.git

ORIGIN_DOCKERFILE=semaphore/deployment/docker/server/Dockerfile/Dockerfile

echo "Updating image base for Docker build from Alpine to UBI $UBI_VERSION with Python version $PYTHON_VERSION:"
sed -i $ORIGIN_DOCKERFILE -e "%s/image tag/FROM registry.access.redhat.com/ubi8/python-312 as builder/g"


echo "Updating image to use glibc instead of MUSL as well as updating the package manager"

echo "Adding build step to use minimal UBI for built image:"

cat Dockerfile-minimal >> $ORIGIN_DOCKERFILE
