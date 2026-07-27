# Seul endroit du lab où Chromium est installé (jamais dans l'image d'une
# app — cf. contrainte 2 vCPU/16 Go, CLAUDE.md). Image officielle Playwright :
# Node + navigateurs déjà installés, aucun `playwright install` au build.
FROM mcr.microsoft.com/playwright:v1.48.0-jammy

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY playwright.config.ts server.js ./
COPY lib ./lib

EXPOSE 4300
CMD ["node", "server.js"]
