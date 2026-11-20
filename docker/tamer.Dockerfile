# lumo-tamer, built from a pinned commit, plus a small sign-in helper.
# Based on lumo-tamer's own Dockerfile.
ARG TAMER_COMMIT=0ef587b

FROM node:22-alpine AS src
ARG TAMER_COMMIT
RUN apk add --no-cache git && git clone -q https://github.com/ZeroTricks/lumo-tamer.git /src \
 && git -C /src checkout -q ${TAMER_COMMIT}

FROM golang:1.24-alpine AS go-builder
WORKDIR /build
COPY --from=src /src/src/auth/login/go ./
# Lumo Stack additions to the login helper:
#  - hv.go: CAPTCHA (human verification) support, retried with the verified token
#  - the password can come from piped input (Lumo Home's form), not only a TTY
COPY tamer/hv.go ./hv.go
RUN sed -i -e 's|proton.WithUserAgent(userAgent),|proton.WithUserAgent(userAgent), proton.WithTransport(newHVTransport()),|' \
           -e 's|client, auth, err := manager.NewClientWithLogin(ctx, username, \[\]byte(password))|client, auth, err := loginWithHV(ctx, manager, reader, username, []byte(password))|' main.go \
 && grep -q 'newHVTransport()' main.go && grep -q 'loginWithHV(' main.go
# Let the password come from piped input (Lumo Home's sign-in form) as well as
# a terminal. Upstream only reads it from a TTY.
RUN sed -i 's|passwordBytes, err := term.ReadPassword(int(syscall.Stdin))|var passwordBytes []byte; if term.IsTerminal(int(syscall.Stdin)) { passwordBytes, err = term.ReadPassword(int(syscall.Stdin)) } else { var line string; line, err = reader.ReadString(10); passwordBytes = []byte(strings.TrimRight(line, "\\r\\n")) }|' main.go \
 && grep -q 'term.IsTerminal' main.go \
 && CGO_ENABLED=0 go build -o proton-auth

FROM node:22-alpine AS builder
WORKDIR /app
COPY --from=src /src/package*.json /src/tsconfig.json ./
# Install scripts skipped: optional native add-ons (canvas, keytar) aren't used
# in the container, and building them needs downloads that often fail.
RUN npm ci --no-audit --no-fund --ignore-scripts
COPY --from=src /src/src ./src
COPY --from=src /src/packages ./packages
RUN npm run build && npm prune --production --ignore-scripts

FROM node:22-alpine
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=src /src/package.json /src/config.defaults.yaml ./
COPY --from=go-builder /build/proton-auth ./dist/proton-auth
RUN npm link >/dev/null 2>&1 && mkdir -p /app/sessions && chown -R node:node /app
COPY --chown=node:node tamer/auth-helper.mjs tamer/start.sh /app/lumo/
RUN chmod 755 /app/lumo/start.sh
USER node
EXPOSE 3003
ENTRYPOINT ["/app/lumo/start.sh"]
