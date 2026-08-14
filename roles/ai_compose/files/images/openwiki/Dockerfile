# OpenWiki CLI -- generates a documentation wiki from a codebase (calls the chat
# LLM). On-demand utility (like repomix/hfcli). Built on the box by ansible.
# Tag: openwiki:latest  (see group_vars ai_compose_images).
FROM node:22.23.1-trixie

# PINNED. This was previously an unpinned `npm install -g openwiki`, so every
# rebuild grabbed whatever was newest -- and one such build landed on a version
# whose @langchain/core dependency had moved, making the viewer die on startup
# ("does not provide an export named 'DEFAULT_LANGSMITH_GATEWAY'"). Pinning makes
# the image reproducible; bump deliberately and re-test `openwiki visualize`.
ARG OPENWIKI_VERSION=0.3.3

# strict-ssl off accommodates a TLS-inspecting corp proxy in the build room (the
# same reason oikb installs the proxy CA). Drop this line if your registry path
# presents a publicly-trusted chain.
RUN npm config set strict-ssl false \
    && npm install -g "openwiki@${OPENWIKI_VERSION}" \
    && apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
