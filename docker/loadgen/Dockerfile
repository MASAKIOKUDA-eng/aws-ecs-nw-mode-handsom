# Load generator image: k6 + iperf3 + the measurement scripts.
# Build from the repository root so the scripts can be copied in:
#   docker build -f docker/loadgen/Dockerfile -t <repo>:v1 .
# Pin the base image by digest before you build for the talk, e.g.
#   --build-arg BASE=grafana/k6@sha256:<digest>
ARG BASE=grafana/k6:latest
FROM ${BASE}
USER root
RUN apk add --no-cache bash iperf3 jq coreutils
COPY scripts/k6-load.js scripts/run-k6.sh scripts/run-iperf.sh /opt/netbench/
RUN chmod 0555 /opt/netbench/*.sh && ln -s /opt/netbench/run-k6.sh /usr/local/bin/run-k6.sh \
 && ln -s /opt/netbench/run-iperf.sh /usr/local/bin/run-iperf.sh
# Results are written to /work/results (mount a host directory there).
WORKDIR /work
USER 12345
ENTRYPOINT []
CMD ["k6", "version"]
