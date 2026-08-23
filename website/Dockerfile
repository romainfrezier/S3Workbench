FROM node:24-alpine AS build

WORKDIR /site
COPY package*.json ./
RUN npm ci
COPY . .

ARG VITE_SITE_URL=https://s3workbench.com
ARG VITE_BASE_PATH=/
ENV VITE_SITE_URL=$VITE_SITE_URL
ENV VITE_BASE_PATH=$VITE_BASE_PATH

RUN npm run build

FROM nginx:1.29.8-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /site/dist /usr/share/nginx/html

HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget --spider --quiet http://127.0.0.1/healthz || exit 1
