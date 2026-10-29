# Test target image: nginx (non-root, port 8080) + iperf3 server + curl (used by the security probe).
# Pin the base image by digest before you build for the talk, e.g.
#   docker build --build-arg BASE=public.ecr.aws/nginx/nginx-unprivileged@sha256:<digest> ...
ARG BASE=public.ecr.aws/nginx/nginx-unprivileged:stable-alpine
FROM ${BASE}

USER root
RUN apk add --no-cache iperf3 curl \
 && mkdir -p /usr/share/nginx/html \
 && head -c 1024    /dev/urandom > /usr/share/nginx/html/1k \
 && head -c 102400  /dev/urandom > /usr/share/nginx/html/100k \
 && head -c 1048576 /dev/urandom > /usr/share/nginx/html/1m \
 && chown -R 101:101 /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf

# nginx-unprivileged runs as uid 101. iperf3 also runs as this user.
USER 101
EXPOSE 8080 5201
CMD ["nginx", "-g", "daemon off;"]
