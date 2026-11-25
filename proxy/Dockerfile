FROM node:22-alpine
WORKDIR /app
COPY server.mjs .
USER node
ENV PORT=8000
EXPOSE 8000
CMD ["node", "server.mjs"]
