FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR /source

COPY sisk.csproj ./
RUN dotnet restore -r linux-musl-x64

COPY . .

RUN dotnet publish -c Release -r linux-musl-x64 --self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime-deps:10.0-alpine
WORKDIR /app
COPY --from=build /app .

RUN apk add --no-cache libmsquic

EXPOSE 8080 8443/tcp 8443/udp
ENTRYPOINT ["./sisk"]