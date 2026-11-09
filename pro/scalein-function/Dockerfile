# Stage 1: install Python dependencies and trim what we don't ship.
FROM fnproject/python:3.12-dev AS build-stage
WORKDIR /function

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

ADD requirements.txt /function/
RUN pip3 install --target /python/packages -r requirements.txt

# The OCI Python SDK ships ~175 service clients (~470 MB). func.py uses only
# oci.core and oci.monitoring, but importing them drags in transitive
# subpackages via oci/__init__.py and oci/pagination (which reference oci.dns
# and oci.object_storage). The keep-list below was found empirically (import
# in the full image, inspect sys.modules); the rest is dead weight. Saves ~430 MB.
RUN set -eux; \
    cd /python/packages/oci; \
    for d in */; do \
        case "${d%/}" in \
            _vendor|auth|circuit_breaker|core|dns|monitoring|object_storage|pagination|retry|work_requests) ;; \
            *) rm -rf "$d" ;; \
        esac; \
    done

# Strip bytecode caches.
RUN find /python/packages -type d -name __pycache__ -exec rm -rf {} + ; \
    find /python/packages -type f -name "*.pyc" -delete

ADD . /function/

# Stage 2: lean runtime image.
FROM fnproject/python:3.12 AS runtime-base
# Apply the Oracle Linux security updates published after the base image was
# built. pip, setuptools and wheel only install packages, which happens in the
# build stage, so they are removed from the runtime together with the
# libraries they vendor.
RUN microdnf upgrade -y && \
    microdnf remove -y python3.12-pip python3.12-setuptools && \
    microdnf clean all && \
    rm -rf /usr/local/lib/python3.12/site-packages/pip \
           /usr/local/lib/python3.12/site-packages/pip-*.dist-info \
           /usr/local/lib/python3.12/site-packages/setuptools \
           /usr/local/lib/python3.12/site-packages/setuptools-*.dist-info \
           /usr/local/lib/python3.12/site-packages/pkg_resources \
           /usr/local/lib/python3.12/site-packages/_distutils_hack \
           /usr/local/lib/python3.12/site-packages/distutils-precedence.pth \
           /usr/local/lib/python3.12/site-packages/wheel \
           /usr/local/lib/python3.12/site-packages/wheel-*.dist-info \
           /usr/local/bin/pip* /usr/local/bin/wheel

# Single-layer runtime: the upgrade above would otherwise add a second copy of
# every updated package on top of the base image layers.
FROM scratch
COPY --from=runtime-base / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /function
COPY --from=build-stage /python/packages /python/packages
COPY --from=build-stage /function /function
ENV PYTHONPATH=/python/packages
ENTRYPOINT ["/python/packages/bin/fdk", "/function/func.py", "handler"]
