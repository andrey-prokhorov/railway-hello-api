FROM node:24-alpine

WORKDIR /app

COPY --chown=node:node package*.json ./
RUN npm ci --omit=dev

COPY --chown=node:node . .

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:${PORT:-3000}/health || exit 1

CMD ["node", "server.js"]
