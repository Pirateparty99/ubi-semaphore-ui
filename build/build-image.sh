#!/bin/bash

UBI_VERSION=9.8
PYTHON_VERSION=3.12

FROM registry.access.redhat.com/ubi8/python-312

git clone https://github.com/semaphoreui/semaphore.git

cd semaphore/deployment/docker/server/Dockerfile

echo "Updating image base for Docker build from Alpine to UBI $UBI_VERSION with Python version $PYTHON_VERSION:"
sed -i Dockerfile -e "%s/

echo "Adding build step to use minimal UBI for built image:"
