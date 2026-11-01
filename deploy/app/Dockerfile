# Campus app for the SP v4 PoC: two WARs built with Maven inside Docker, run on Jetty 12.
#   /secure  index.jsp (identity dump) + /secure/callapi (service-account token -> API)
#   /api     test resource server validating Google-signed ID tokens
#   /public  exploded JSP, no session required

FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
COPY secure/pom.xml secure/
COPY api/pom.xml api/
# warm the dependency cache in its own layer
RUN mvn -q -B -ntp dependency:go-offline || true
COPY secure/src secure/src
COPY api/src api/src
RUN mvn -q -B -ntp package

FROM jetty:12-jdk17
COPY --from=build /src/secure/target/secure.war /var/lib/jetty/webapps/secure.war
COPY --from=build /src/api/target/api.war       /var/lib/jetty/webapps/api.war
COPY public /var/lib/jetty/webapps/public
# secrets (service-account key) are bind-mounted at /var/lib/jetty/secrets
