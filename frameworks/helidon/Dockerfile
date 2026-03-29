FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /app/target/helidon-httparena.jar app.jar
COPY --from=build /app/target/libs ./libs
EXPOSE 8080
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseZGC", \
  "-XX:+UseNUMA", \
  "-XX:+AlwaysPreTouch", \
  "-cp", "app.jar:libs/*", \
  "com.httparena.Main"]
