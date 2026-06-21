FROM ubuntu:24.04

ARG TAILSCALE_VERSION=

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl dante-server \
 && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list \
 && apt-get update \
 && if [ -n "$TAILSCALE_VERSION" ]; then \
      apt-get install -y --no-install-recommends "tailscale=${TAILSCALE_VERSION}"; \
    else \
      apt-get install -y --no-install-recommends tailscale; \
    fi \
 && rm -rf /var/lib/apt/lists/*

COPY danted.conf /etc/danted.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
