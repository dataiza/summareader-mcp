# Build.
#
# An ordinary context, rooted here. The Dart version needed the *parent*
# directory because it shared the protocol with the app by path dependency;
# this one carries its own implementation of that protocol, checked against the
# app's test vectors, so nothing outside this repository is needed to build it.
# That is the one clear simplification the port bought.
FROM python:3.13-slim AS build

WORKDIR /src
RUN pip install --no-cache-dir build

COPY pyproject.toml README.md ./
COPY summareader_mcp/ ./summareader_mcp/
RUN python -m build --wheel --outdir /dist

# Run.
#
# As little as possible in the image beside the key: this process holds the
# master key and a plaintext copy of the library, so the runtime carries no
# build tools and no source tree.
FROM python:3.13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --home-dir /cache summareader

COPY --from=build /dist/*.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl && rm /tmp/*.whl

# The decrypted copy. A cache: rebuildable from the log, safe to delete, and
# never the only copy of anything — though it is now the *most complete* one,
# because a mirror runs no retention. See the README.
VOLUME /cache
USER summareader

EXPOSE 8100

HEALTHCHECK --interval=60s --timeout=5s --start-period=20s \
    CMD curl -fsS http://127.0.0.1:8100/health || exit 1

# HTTP rather than stdio, because a container is not a subprocess its client
# can start.
CMD ["summareader-mcp", "serve", "--transport=http", "--port=8100"]
