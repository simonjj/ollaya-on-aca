FROM node:22-alpine

WORKDIR /app
COPY app/api/package.json app/api/package-lock.json ./
RUN npm ci --omit=dev

COPY app/api/ ./
COPY app/taxonomy.json ./taxonomy.json

ENV NODE_ENV=production
EXPOSE 8080
USER node

CMD ["node", "server.js"]
