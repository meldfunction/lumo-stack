# Sign-in browser: Chromium you use from your own browser (https://localhost:3001).
# Its debugging port (9222) is only reachable inside Docker, by lumo-tamer.
# Based on lumo-tamer's Dockerfile.browser, pinned.
FROM lscr.io/linuxserver/chromium:075b0b99-ls64
RUN apt-get update && apt-get install -y --no-install-recommends socat && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/cont-init.d \
 && printf '#!/usr/bin/with-contenv bash\nsocat TCP-LISTEN:9222,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:9221 &\n' > /etc/cont-init.d/99-socat \
 && chmod +x /etc/cont-init.d/99-socat
EXPOSE 9222 3001
