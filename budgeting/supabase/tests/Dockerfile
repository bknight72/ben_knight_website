# syntax=docker/dockerfile:1
FROM denoland/deno:latest
USER root
RUN --mount=type=secret,id=corporate_ca \
    if [ -s /run/secrets/corporate_ca ]; then cp /run/secrets/corporate_ca /usr/local/share/ca-certificates/budgeting-corporate.crt; update-ca-certificates; fi; \
    apt-get update && apt-get install -y --no-install-recommends nodejs npm && rm -rf /var/lib/apt/lists/*
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker
WORKDIR /workspace
LABEL org.opencontainers.image.vendor="Novacoast-VCA-805"
ENTRYPOINT []
