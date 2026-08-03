# Build.
#
# The build context has to be the parent directory, because this package
# depends on allreader_core by path — it lives in the app's repository, and a
# context rooted here could not see it. Compose does that; a bare `docker
# build .` here will not.
FROM dart:stable AS build

WORKDIR /src

# The shared protocol package, copied first: it changes far less often than
# this server does, so a change here does not re-resolve it.
COPY allreader/packages/allreader_core/ ./allreader/packages/allreader_core/

COPY allreader-mcp/pubspec.yaml ./allreader-mcp/
WORKDIR /src/allreader-mcp
RUN dart pub get

COPY allreader-mcp/ ./
RUN dart pub get --offline && dart compile exe bin/allreader_mcp.dart -o /allreader-mcp

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
    && useradd --uid 10001 --create-home --home-dir /cache allreader

COPY --from=build /allreader-mcp /usr/local/bin/allreader-mcp

# The decrypted copy. A cache: rebuildable from the log, safe to delete, and
# never the only copy of anything.
VOLUME /cache
USER allreader

EXPOSE 8100

# HTTP rather than stdio, because a container is not a subprocess its client
# can start.
CMD ["allreader-mcp", "--transport=http", "--port=8100"]
