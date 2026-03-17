FROM gradle:8.12-jdk21 AS build
WORKDIR /app
COPY build.gradle.kts settings.gradle.kts gradle.properties ./
RUN gradle dependencies --no-daemon -q 2>/dev/null || true
COPY src ./src
RUN gradle buildFatJar --no-daemon -q

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/ktor-httparena.jar .
EXPOSE 8080
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseParallelGC", \
  "-XX:+UseNUMA", \
  "-XX:-StackTraceInThrowable", \
  "-Dio.netty.buffer.checkBounds=false", \
  "-Dio.netty.buffer.checkAccessible=false", \
  "-jar", "ktor-httparena.jar"]
