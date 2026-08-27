# Managed by ansible (nmap_container). A containerised nmap for FIPS hosts.
#
# The host's nmap quits at startup under FIPS -- its OpenSSL is the FIPS variant
# and offers no usable cipher suite. This base image carries stock OpenSSL, so
# nmap starts normally. The host kernel stays in FIPS mode.
ARG BASE=ubuntu:24.04
FROM ${BASE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends nmap ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["nmap"]
