# Minimal, dependency-free auth-swap proxy image.
FROM node:20-alpine

# Run as non-root.
WORKDIR /app
COPY package.json server.js ./
USER node

ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "server.js"]
