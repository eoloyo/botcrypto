# GraalVM native executable (built by 15-native-build.sh); needs only glibc >= 2.39 + zlib
FROM public.ecr.aws/docker/library/ubuntu:24.04
RUN useradd -u 1001 app
COPY --chown=1001 identity-provider /app/identity-provider
USER 1001
ENTRYPOINT ["/app/identity-provider", "-Dlog4j2.Configuration.allowedProtocols=resource,file,jar,https", "-Dio.lettuce.core.jfr=false"]
