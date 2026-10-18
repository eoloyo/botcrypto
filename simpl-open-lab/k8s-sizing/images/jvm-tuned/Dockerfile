# Improved JVM image: JRE (not JDK), extracted jar (no nested-jar class loading), CDS archive written to
# /cds on the first run (AutoCreateSharedArchive) and reused afterwards; start-up-friendly JVM flags.
FROM eclipse-temurin:21-jre-alpine
RUN adduser -S -u 1001 1001 && mkdir /cds && chown 1001 /cds
COPY app.jar /tmp/app.jar
RUN java -Djarmode=tools -jar /tmp/app.jar extract --destination /app && rm /tmp/app.jar && chown -R 1001 /app
USER 1001
ENTRYPOINT ["sh", "-c", "exec java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -Xss512k -XX:MaxRAMPercentage=50 -XX:SharedArchiveFile=/cds/app.jsa -XX:+AutoCreateSharedArchive -jar /app/$(ls /app | grep '\\.jar$' | head -1)"]
