# Stage 1: install Python dependencies and trim what we don't ship.
FROM fnproject/python:3.11-dev AS build-stage
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
FROM fnproject/python:3.11
WORKDIR /function
COPY --from=build-stage /python/packages /python/packages
COPY --from=build-stage /function /function
ENV PYTHONPATH=/python/packages
ENTRYPOINT ["/python/packages/bin/fdk", "/function/func.py", "handler"]
