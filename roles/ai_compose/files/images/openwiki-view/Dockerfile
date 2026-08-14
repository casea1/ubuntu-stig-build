# openwiki-view -- LAN front-end for `openwiki visualize`.
# Tag: openwiki-view:latest  (see group_vars ai_compose_images). Built on the box.
#
# It solves two problems the openwiki viewer has on its own:
#   1. `openwiki visualize` binds 127.0.0.1 ONLY (no bind/host flag), so it is
#      unreachable from the network. This nginx shares the viewer's network
#      namespace (compose `network_mode: service:openwiki-view`) and listens on
#      0.0.0.0:8080, proxying to the viewer on 127.0.0.1:4321.
#   2. The viewer's HTML pulls its four front-end libraries from a public CDN
#      (cdn.jsdelivr.net), so the graph/markdown/diagrams do not render on an
#      air-gapped box. We VENDOR those libraries into this image at build time
#      (mirroring jsdelivr's paths exactly) and nginx rewrites the CDN prefix to
#      the local /vendor/ path on the way out. Fully offline after build.
FROM nginx:1.30.4-alpine

# Pinned to the exact versions the viewer requests (openwiki 0.3.3). If a future
# openwiki bumps them, the page falls back to the CDN -> update these to match,
# or the graph silently stops rendering offline. Paths mirror jsdelivr so a
# single sub_filter prefix rewrite is enough.
ARG FORCE_GRAPH=1.49.5
ARG MARKED=12.0.2
ARG DOMPURIFY=3.4.12
ARG MERMAID=11.16.0

RUN set -eux; \
    # busybox wget needs a CA bundle to fetch over TLS; the nginx image does not
    # ship one. (Behind a TLS-inspecting proxy, add your CA the way oikb does.)
    apk add --no-cache ca-certificates; \
    v=/usr/share/nginx/vendor; \
    mkdir -p "$v/force-graph@${FORCE_GRAPH}/dist" \
             "$v/marked@${MARKED}" \
             "$v/dompurify@${DOMPURIFY}/dist" \
             "$v/mermaid@${MERMAID}/dist"; \
    base=https://cdn.jsdelivr.net/npm; \
    wget -qO "$v/force-graph@${FORCE_GRAPH}/dist/force-graph.min.js" \
        "$base/force-graph@${FORCE_GRAPH}/dist/force-graph.min.js"; \
    wget -qO "$v/marked@${MARKED}/marked.min.js" \
        "$base/marked@${MARKED}/marked.min.js"; \
    wget -qO "$v/dompurify@${DOMPURIFY}/dist/purify.min.js" \
        "$base/dompurify@${DOMPURIFY}/dist/purify.min.js"; \
    wget -qO "$v/mermaid@${MERMAID}/dist/mermaid.min.js" \
        "$base/mermaid@${MERMAID}/dist/mermaid.min.js"; \
    # fail the build rather than ship an empty asset that 404s at runtime
    find "$v" -name '*.js' -size -1k -exec false {} +

COPY openwiki-view.conf /etc/nginx/conf.d/default.conf
