
FROM dunglas/frankenphp:latest-builder as builder

# Copy xcaddy in the builder image
COPY --from=caddy:builder /usr/bin/xcaddy /usr/bin/xcaddy


# CGO must be enabled to build FrankenPHP
ENV CGO_ENABLED=1 XCADDY_SETCAP=1 XCADDY_GO_BUILD_FLAGS='-ldflags="-w -s" -trimpath'


RUN xcaddy build \
    --output /usr/local/bin/frankenphp \
    --with github.com/dunglas/frankenphp=./ \
    --with github.com/dunglas/frankenphp/caddy=./caddy/ \
    # Mercure and Vulcain are included in the official build, but feel free to remove them
    --with github.com/dunglas/mercure/caddy \
    --with github.com/dunglas/vulcain/caddy  \
    --with github.com/dunglas/caddy-cbrotli \
    # Add extra Caddy modules here
    --with github.com/caddyserver/cache-handler
