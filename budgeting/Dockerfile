FROM debian:latest AS tooling
LABEL org.opencontainers.image.vendor="Novacoast-VCA-805"
ENV DEBIAN_FRONTEND=noninteractive
ARG BUILDER_UID=1000
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils libglu1-mesa \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch stable https://github.com/flutter/flutter.git /opt/flutter \
    && test "$BUILDER_UID" -ne 0 \
    && useradd --create-home --uid "$BUILDER_UID" builder \
    && mkdir /workspace && chown -R builder:builder /opt/flutter /workspace
ENV PATH="/opt/flutter/bin:${PATH}"
RUN --mount=type=secret,id=build_ca,mode=0444 \
    if [ -f /run/secrets/build_ca ]; then cp /run/secrets/build_ca /usr/local/share/ca-certificates/build-ca.crt; update-ca-certificates; fi \
    && curl --fail --silent --show-error --max-time 20 https://pub.dev/api/packages/http -o /dev/null \
    && su builder -c 'export PATH=/opt/flutter/bin:$PATH; flutter config --enable-web --no-analytics && flutter precache --web' \
    && rm -f /usr/local/share/ca-certificates/build-ca.crt && update-ca-certificates --fresh
USER builder
WORKDIR /workspace
CMD ["bash"]

FROM tooling AS build
COPY --chown=builder:builder . .
ARG SUPABASE_URL
ARG SUPABASE_PUBLISHABLE_KEY
ARG STRIPE_PUBLISHABLE_KEY
ARG STRIPE_ENABLED=false
USER root
RUN --mount=type=secret,id=build_ca,mode=0444 \
    if [ -f /run/secrets/build_ca ]; then cp /run/secrets/build_ca /usr/local/share/ca-certificates/build-ca.crt; update-ca-certificates; fi \
    && su builder -c 'export PATH=/opt/flutter/bin:$PATH; flutter pub get'
USER builder
RUN flutter build web --release --no-web-resources-cdn \
    --dart-define=SUPABASE_URL=${SUPABASE_URL} \
    --dart-define=SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY} \
    --dart-define=STRIPE_PUBLISHABLE_KEY=${STRIPE_PUBLISHABLE_KEY} \
    --dart-define=STRIPE_ENABLED=${STRIPE_ENABLED}

FROM nginx:latest AS runtime
LABEL org.opencontainers.image.vendor="Novacoast-VCA-805"
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /tmp/nginx && chown nginx:nginx /tmp/nginx
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build /workspace/build/web /usr/share/nginx/html
USER nginx
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD curl --fail http://127.0.0.1:8080/health || exit 1
STOPSIGNAL SIGQUIT
ENTRYPOINT ["nginx", "-g", "daemon off;"]
