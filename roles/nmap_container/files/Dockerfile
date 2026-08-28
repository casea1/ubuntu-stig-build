# Managed by ansible (nmap_container). A containerised nmap for FIPS hosts.
#
# The host's nmap quits at startup under FIPS -- its OpenSSL offers no usable
# cipher suite. This image runs nmap against a stock OpenSSL instead, with
# it-vulnscan mounting `fips_off` over /proc/sys/crypto/fips_enabled at RUN
# time. The host kernel stays in FIPS mode.
#
# ca-certificates is deliberately NOT installed. Two reasons:
#  1. It buys nothing here. nmap's TLS scripts (ssl-cert, ssl-enum-ciphers,
#     the http-* probes) read what a target presents; they do not validate it
#     against a CA bundle.
#  2. On ASP-2 its postinst was the ONLY thing that failed the build, dying
#     once per certificate (146 of them) with a bare "out of memory" while
#     nmap and every other package installed cleanly. Root cause NOT
#     confirmed -- see docs/procedures.md 3.3. RLIMIT_NOFILE was the first
#     theory and is ruled out. What is established: `docker build` cannot
#     apply the fips_off carve-out the runtime uses, and Ubuntu's stock
#     libcrypto.so.3 does contain /proc/sys/crypto/fips_enabled -- so a
#     container on a FIPS host is not the non-FIPS OpenSSL environment it
#     looks like.
ARG BASE=ubuntu:24.04
FROM ${BASE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends nmap \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["nmap"]
