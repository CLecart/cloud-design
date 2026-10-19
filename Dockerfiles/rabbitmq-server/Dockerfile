# RabbitMQ 4 message broker built from the Alpine package (no pre-built rabbitmq image).
# The broker configuration (including credentials) is generated at container start by
# docker-entrypoint.sh, so nothing secret is ever stored in the image layers.
FROM alpine:3.23

LABEL org.opencontainers.image.title="rabbitmq" \
      org.opencontainers.image.description="RabbitMQ message broker (AMQP 0-9-1) carrying billing messages from api-gateway-app to billing-app" \
      org.opencontainers.image.authors="clecart"

# tini reaps zombies and forwards SIGTERM to the broker for a clean shutdown.
# /etc/rabbitmq is not created by the package; the broker and its config run as user rabbitmq (uid 100).
RUN apk add --no-cache rabbitmq-server tini \
    && mkdir -p /etc/rabbitmq \
    && chown -R rabbitmq:rabbitmq /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq

# Fixed node name so the Erlang node does not depend on the (random) container hostname.
ENV RABBITMQ_NODENAME=rabbit@localhost

COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/

USER rabbitmq

# AMQP listener only: the management plugin is not enabled and no port is published on the host.
EXPOSE 5672

HEALTHCHECK --interval=10s --timeout=10s --start-period=40s --retries=5 \
    CMD ["rabbitmq-diagnostics", "-q", "check_port_connectivity"]

ENTRYPOINT ["/sbin/tini", "--", "docker-entrypoint.sh"]
CMD ["rabbitmq-server"]
