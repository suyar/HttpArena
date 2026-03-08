FROM node:22-slim
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev
COPY app.js .
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "app.js"]
