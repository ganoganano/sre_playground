FROM node:22-alpine

WORKDIR /app

ARG APP_COLOR=blue
ARG APP_VERSION=v1

COPY package.json ./
COPY server.js ./

ENV PORT=8080
ENV APP_COLOR=${APP_COLOR}
ENV APP_VERSION=${APP_VERSION}

EXPOSE 8080

CMD ["node", "server.js"]
