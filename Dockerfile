# Official Hermes image plus what this setup needs on top:
#   - sops and age: secrets are decrypted inside the container at start
#   - uv on PATH and the himalaya mail CLI: used by cron jobs
#
# The Hermes version is pinned here, so that every build of one commit gives
# the same agent. To upgrade Hermes, change the tag of the "pinned" stage below
# (see README, Releasing a new version); Dependabot opens a pull request for
# it when Hermes publishes a new one, which is why the tag is written out in a
# FROM line of its own. HERMES_IMAGE_TAG overrides it for one build, e.g.
# v0.23.1-desktop for Bot Desktop; the pinned stage is then not used.
ARG HERMES_IMAGE_TAG=
ARG HERMES_BASE=${HERMES_IMAGE_TAG:+nousresearch/hermes-agent:}${HERMES_IMAGE_TAG:-pinned}
FROM nousresearch/hermes-agent:v0.23.1 AS pinned
FROM ${HERMES_BASE}

# Keep the root entrypoint; s6 drops privileges for the runtime.
USER root

# Secrets are kept in git, encrypted with SOPS for an age key, and decrypted
# when the container starts. Checksums are the ones GitHub publishes for the
# release assets; the build fails if a download differs.
ARG SOPS_VERSION=3.13.3
ARG SOPS_SHA256=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
ADD --checksum=sha256:${SOPS_SHA256} --chmod=0755 \
    https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64 \
    /usr/local/bin/sops
ARG AGE_VERSION=1.3.2
ARG AGE_SHA256=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
ADD --checksum=sha256:${AGE_SHA256} \
    https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz \
    /tmp/age.tgz
RUN tar -xzf /tmp/age.tgz -C /usr/local/bin --strip-components=1 age/age age/age-keygen \
 && rm /tmp/age.tgz \
 && SOPS_DISABLE_VERSION_CHECK=1 sops --version \
 && age --version

# Cron jobs call `uv`; the base image ships it outside PATH.
RUN set -e; for tool in uv uvx; do \
      bin="$(ls /opt/hermes/tools/uv-*/"$tool" | head -n1)"; \
      ln -s "$bin" "/usr/local/bin/$tool"; \
    done; uv --version

# Mail CLI used by cron jobs. The checksum is the one GitHub publishes for the
# release asset; the build fails if the download differs.
ARG HIMALAYA_VERSION=1.2.0
ARG HIMALAYA_SHA256=e04e6382e3e664ef34b01afa1a2216113194a2975d2859727647b22d9b36d4e4
ADD --checksum=sha256:${HIMALAYA_SHA256} \
    https://github.com/pimalaya/himalaya/releases/download/v${HIMALAYA_VERSION}/himalaya.x86_64-linux.tgz \
    /tmp/himalaya.tgz
RUN tar -xzf /tmp/himalaya.tgz -C /usr/local/bin himalaya \
 && rm /tmp/himalaya.tgz \
 && himalaya --version

# Hermes zstd-compresses request bodies for chatgpt.com/backend-api/codex, and
# that backend answers some of them (seen only above 128 KiB) with
# HTTP 400 {"detail":"Bad Request"}; the same body uncompressed is accepted.
# There is no setting for it, so make the codec import fail: Hermes then sends
# plain JSON. The build fails if this no longer applies to a newer Hermes;
# check whether the workaround is still needed and drop or adapt it.
RUN set -e; f=/opt/hermes/agent/codex_headers.py; \
    grep -q '^        from compression import zstd$' "$f"; \
    sed -i 's/^        from compression import zstd$/        raise ImportError("zstd request compression is disabled, see Dockerfile")/' "$f"; \
    cd /opt/hermes && .venv/bin/python -c 'from agent.codex_headers import codex_request_compression_hooks as hooks; assert hooks("https://chatgpt.com/backend-api/codex") is None and hooks("https://chatgpt.com/backend-api/codex", async_mode=True) is None'

COPY --chmod=0755 docker/secrets-entrypoint.sh /usr/local/bin/secrets-entrypoint

# The image also carries the files a server needs around the containers
# (compose.yaml, the scripts, the systemd units), so that an installation
# needs nothing but this image: docker/extract.sh copies them to the host.
# Only what is listed here goes in; instance/ never does (see .dockerignore).
COPY --chmod=0755 docker/extract.sh /usr/local/bin/hermes-box-extract
COPY compose.yaml install.sh setup.sh check.sh sops.sh Dockerfile README.md LICENSE /opt/hermes-box/
COPY backup /opt/hermes-box/backup
COPY caddy /opt/hermes-box/caddy
COPY deploy /opt/hermes-box/deploy
COPY docker /opt/hermes-box/docker
COPY instance.example /opt/hermes-box/instance.example
COPY monitor /opt/hermes-box/monitor
COPY server /opt/hermes-box/server
# A published image knows its own name: release.env tells the scripts on the
# host which image to run, instead of building one there. Empty for a local
# build, which then keeps the name hermes-agent-local.
ARG HERMES_BOX_IMAGE=
RUN if [ -n "$HERMES_BOX_IMAGE" ]; then \
      printf '# Written when the image was published; read by install.sh and compose.\nHERMES_BOX_IMAGE=%s\n' "$HERMES_BOX_IMAGE" > /opt/hermes-box/release.env; \
    fi
LABEL org.opencontainers.image.source="https://github.com/danielrataj/hermes-box" \
      org.opencontainers.image.licenses="MIT"
ENTRYPOINT ["/usr/local/bin/secrets-entrypoint"]
CMD []
