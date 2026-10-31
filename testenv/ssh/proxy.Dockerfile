# An HTTP proxy that wants a login (Basic) and allows CONNECT to port 22
# only, like a company proxy in front of SSH.
FROM alpine:3.20
RUN apk add --no-cache tinyproxy \
    && printf '%s\n' \
        'Port 8888' \
        'Listen 0.0.0.0' \
        'Timeout 600' \
        'Allow 0.0.0.0/0' \
        'BasicAuth proxyuser proxy-test-password' \
        'ConnectPort 22' \
        'LogLevel Info' \
        > /etc/tinyproxy/tinyproxy.conf
EXPOSE 8888
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
