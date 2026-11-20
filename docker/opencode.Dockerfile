# OpenCode coding agent for Lumo. Runs as the unprivileged "node" user; the
# launcher (lumo-code) mounts only ~/lumo/{code,inbox,out} into it.
FROM node:22-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates ripgrep python3 \
 && rm -rf /var/lib/apt/lists/*
RUN npm install -g opencode-ai@1.19.5 && npm cache clean --force
USER node
ENV HOME=/home/node
RUN mkdir -p /home/node/.config/opencode /home/node/.cache /home/node/.local/share
WORKDIR /lumo/code
ENTRYPOINT ["opencode"]
