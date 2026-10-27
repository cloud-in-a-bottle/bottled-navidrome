# Pinned by tag and multi-arch index digest; bump both to upgrade.
FROM docker.io/deluan/navidrome:0.64.2@sha256:38dc2727bfcfd5ede290f8ada114fc90368146f265ae4701ddddbcbe2a44ee52

USER root

# Navidrome image is Alpine-based. The OpenHost auth-proxy sidecar uses
# only the Python stdlib.
RUN apk add --no-cache python3

COPY start.sh /app/start.sh
COPY auth_proxy.py /app/auth_proxy.py
COPY seed_admin.py /app/seed_admin.py
RUN chmod +x /app/start.sh

EXPOSE 3000

ENTRYPOINT []
CMD ["/app/start.sh"]
