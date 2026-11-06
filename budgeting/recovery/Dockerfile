FROM postgres:latest
LABEL org.opencontainers.image.vendor="Novacoast-VCA-805"
RUN apt-get update && apt-get install -y --no-install-recommends age ca-certificates python3 && rm -rf /var/lib/apt/lists/*
COPY run.sh connect.py sanitize.sql /recovery/
USER postgres
ENTRYPOINT ["python3", "/recovery/connect.py"]
