# Managed by ansible (nmap_container). A containerised nmap for FIPS hosts.
#
# The host's nmap quits at startup under FIPS -- its OpenSSL is the FIPS variant
# and offers no usable cipher suite. This base image carries stock OpenSSL, so
# nmap starts normally. The host kernel stays in FIPS mode.
ARG BASE=ubuntu:24.04
FROM ${BASE}
# ca-certificates is deliberately NOT installed. It is not needed to scan --
# nmap's TLS scripts (ssl-cert, ssl-enum-ciphers, the http-* probes) read what a
# target presents and do not validate it against a CA bundle -- and on ASP-2 its
# postinst was the one thing that failed the build, dying in `openssl rehash`
# with a wall of "out of memory". That is the well-known container symptom of an
# enormous RLIMIT_NOFILE: dockerd ships LimitNOFILE=infinity, containers inherit
# it, and anything that sizes a buffer from the fd limit tries to allocate for a
# billion descriptors. The build also passes --ulimit nofile to bound it, but
# the package buys nothing here, so the simplest fix is not to install it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends nmap \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["nmap"]
