FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends cron ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY src/ ./src/
COPY packaging/ ./packaging/
COPY container/ ./container/

RUN pwsh -NoProfile -ExecutionPolicy Bypass -File ./packaging/build-action1-payload.ps1

ENTRYPOINT ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "/app/container/entrypoint.ps1"]
