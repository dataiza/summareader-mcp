# Build.
#
# The build context has to be the parent directory, because this package
# depends on summareader_core by path — it lives in the app's repository, and a
# context rooted here could not see it. Compose does that; a bare `docker
# build .` here will not.
FROM dart:stable AS build

WORKDIR /src

# The shared protocol package, copied first: it changes far less often than
# this server does, so a change here does not re-resolve it.
COPY summareader/packages/summareader_core/ ./summareader/packages/summareader_core/

COPY summareader-mcp/pubspec.yaml ./summareader-mcp/
WORKDIR /src/summareader-mcp
RUN dart pub get

COPY summareader-mcp/ ./
RUN dart pub get --offline && dart compile exe bin/summareader_mcp.dart -o /summareader-mcp

# Run.
#
# The runtime image carries no Dart SDK and no source — an AOT binary and the
# few libraries it links against. That matters more here than usually: this
# process holds the master key, so the less that is in the image with it the
# better.
FROM debian:stable-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --home-dir /cache summareader

COPY --from=build /summareader-mcp /usr/local/bin/summareader-mcp

# The decrypted copy. A cache: rebuildable from the log, safe to delete, and
# never the only copy of anything.
VOLUME /cache
USER summareader

EXPOSE 8100

# HTTP rather than stdio, because a container is not a subprocess its client
# can start.
CMD ["summareader-mcp", "--transport=http", "--port=8100"]
