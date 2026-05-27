# Stage 1: install Python dependencies
FROM fnproject/python:3.11-dev AS build-stage
WORKDIR /function
ADD requirements.txt /function/
RUN pip3 install --target /python/packages -r requirements.txt
ADD . /function/

# Stage 2: lean runtime image
FROM fnproject/python:3.11
WORKDIR /function
COPY --from=build-stage /python/packages /python/packages
COPY --from=build-stage /function /function
ENV PYTHONPATH=/python/packages
ENTRYPOINT ["/python/packages/bin/fdk", "/function/func.py", "handler"]
