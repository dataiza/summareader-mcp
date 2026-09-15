# The container for a released headless bundle.
#
# Separate from the Dockerfile at the root of the repository, and the
# difference is the first stage: that one builds the wheel from source, which a
# download has none of. This one installs the wheel the release already built.
#
# The wheel and not the frozen binary beside it, deliberately. A frozen bundle
# carries the interpreter of the machine that froze it and is linked against
# that machine's libc — put one built on a rolling-release runner into a Debian
# image and it fails to start, with an error about a symbol version rather than
# about what is actually wrong. A wheel is pure Python and does not care.
FROM python:3.13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --home-dir /cache summareader

COPY summareader_mcp-*.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl && rm /tmp/*.whl

# The decrypted copy. A cache: rebuildable from the log, safe to delete, and
# never the only copy of anything — though it is the *most complete* one,
# because a mirror runs no retention.
VOLUME /cache
USER summareader

EXPOSE 8100

HEALTHCHECK --interval=60s --timeout=5s --start-period=20s \
    CMD curl -fsS http://127.0.0.1:8100/health || exit 1

# The paths this image has always used. The compose file mounts the config
# here and the cache volume there.
ENV SUMMAREADER_MCP_CONFIG=/config/summareader-mcp.json \
    SUMMAREADER_MCP_CACHE=/cache

# HTTP rather than stdio, because a container is not a subprocess its client
# can start. Every interface, because loopback inside a container is reachable
# by nothing and the port is published by the runtime.
CMD ["summareader-mcp", "serve", "--transport=http", "--host=0.0.0.0", "--port=8100"]
