FROM node:22-alpine AS builder

WORKDIR /app

ARG NEXT_PUBLIC_API_BASE_URL=http://localhost:8000
ENV NEXT_PUBLIC_API_BASE_URL=${NEXT_PUBLIC_API_BASE_URL}

COPY package.json package-lock.json* ./
RUN npm install

COPY app ./app
COPY next.config.ts ./
COPY tsconfig.json ./
COPY next-env.d.ts ./

RUN npm run build

FROM node:22-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=8080
ENV HOSTNAME=0.0.0.0

COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/package-lock.json* ./
RUN npm install --omit=dev

COPY --from=builder /app/.next ./.next
COPY --from=builder /app/app ./app
COPY --from=builder /app/next.config.ts ./

CMD ["sh", "-c", "npm run start -- --hostname 0.0.0.0 --port ${PORT}"]
