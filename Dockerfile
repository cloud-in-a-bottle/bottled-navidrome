FROM deluan/navidrome:latest

USER root

# Navidrome image is Alpine-based. The OpenHost auth-proxy sidecar uses
# only the Python stdlib.
RUN apk add --no-cache python3

COPY start.sh /app/start.sh
COPY auth_proxy.py /app/auth_proxy.py
RUN chmod +x /app/start.sh

EXPOSE 3000

ENTRYPOINT []
CMD ["/app/start.sh"]
