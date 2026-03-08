FROM denoland/deno:2.2.2
WORKDIR /app
COPY main.ts .
RUN deno cache main.ts
EXPOSE 8080
CMD ["deno", "serve", "--parallel", "--port", "8080", "--host", "0.0.0.0", "-A", "main.ts"]
