FROM node:latest
LABEL org.opencontainers.image.vendor="Novacoast-VCA-805"
WORKDIR /runner
RUN --mount=type=secret,id=build_ca,mode=0444 \
    if [ -f /run/secrets/build_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/build_ca; fi; \
    npm install --no-package-lock playwright && npx playwright install --with-deps chromium
COPY integration_test/artifact_test.js /runner/artifact_test.mjs
CMD ["node", "/runner/artifact_test.mjs"]
