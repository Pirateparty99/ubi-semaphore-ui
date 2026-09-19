#!/bin/bash

UBI_VERSION=9.8
PYTHON_VERSION=3.12

FROM registry.access.redhat.com/ubi8/python-312

git clone https://github.com/semaphoreui/semaphore.git

ORIGIN_DOCKERFILE=semaphore/deployment/docker/server/Dockerfile/Dockerfile

echo "Updating image base for Docker build from Alpine to UBI $UBI_VERSION with Python version $PYTHON_VERSION:"
sed -i $ORIGIN_DOCKERFILE -e "%s/

echo "Updating 

echo "Adding build step to use minimal UBI for built image:"

cat Dockerfile-minimal >> $ORIGIN_DOCKERFILE
