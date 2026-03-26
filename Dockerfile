FROM deluan/navidrome:latest

USER root

# Navidrome image is Alpine-based
RUN apk add --no-cache caddy

COPY start.sh /app/start.sh
COPY Caddyfile /app/Caddyfile
RUN chmod +x /app/start.sh

EXPOSE 3000

ENTRYPOINT []
CMD ["/app/start.sh"]
