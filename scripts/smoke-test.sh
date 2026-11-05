#!/usr/bin/env bash
#
# Smoke test for the built FrankenWP image.
#
# It starts the image and verifies that the parts that the build touches
# actually work at runtime:
#
#   * the container starts as the unprivileged run user
#   * the WordPress files are unpacked into /var/www/html
#   * the bundled MU plugins are in place
#   * the custom Caddy modules (wp_cache, brotli encoder) are registered
#   * the PHP extensions the image ships are loaded
#   * Caddy serves requests and the cache purge API answers
#
# Usage: smoke-test.sh <image-tag> [port]
#
set -Eeuo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-tag> [port]}"
PORT="${2:-18080}"
CONTAINER="frankenwp-smoke-$$"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "  ok: $*"
}

echo "==> Smoke testing ${IMAGE} on port ${PORT}"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
    -p "127.0.0.1:${PORT}:80" \
    -e SERVER_NAME=":80" \
    -e CADDY_GLOBAL_OPTIONS="auto_https disable_redirects" \
    -e WORDPRESS_DB_HOST=db \
    -e WORDPRESS_DB_USER=user \
    -e WORDPRESS_DB_PASSWORD=pass \
    -e WORDPRESS_DB_NAME=database \
    "$IMAGE" >/dev/null

# The container needs a moment to unpack WordPress and start Caddy.
echo "==> Waiting for the container to become healthy"
healthy=0
for _ in $(seq 1 60); do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || true)" = "healthy" ]; then
        healthy=1
        break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != "true" ]; then
        echo "--- container logs ---" >&2
        docker logs "$CONTAINER" >&2 || true
        fail "the container exited during startup"
    fi
    sleep 2
done

if [ "$healthy" != "1" ]; then
    echo "--- container logs ---" >&2
    docker logs "$CONTAINER" >&2 || true
    fail "the container did not become healthy in time"
fi
pass "container is healthy"

# The run user must not be root: the image sets CAP_NET_BIND_SERVICE so that
# it can bind to port 80 without privileges.
run_user="$(docker exec "$CONTAINER" id -u)"
[ "$run_user" != "0" ] || fail "the container runs as root"
pass "runs as an unprivileged user (uid ${run_user})"

# The WordPress tree has to be unpacked by the entrypoint.
docker exec "$CONTAINER" test -f /var/www/html/wp-includes/version.php \
    || fail "WordPress was not unpacked into /var/www/html"
pass "WordPress is unpacked"

# The MU plugins of this repository must be present.
docker exec "$CONTAINER" test -f /usr/src/wordpress/wp-content/mu-plugins/contentCachePurge.php \
    || fail "the contentCachePurge MU plugin is missing"
docker exec "$CONTAINER" test -f /usr/src/wordpress/wp-content/mu-plugins/forceUrlRewrite.php \
    || fail "the forceUrlRewrite MU plugin is missing"
pass "the bundled MU plugins are in place"

# The custom Caddy modules have to be compiled into the binary.
#
# The output is captured into a variable first and matched with a here-string.
# Piping into "grep -q" directly makes grep close the pipe as soon as it has
# a match, which kills the producer with SIGPIPE; under "set -o pipefail" that
# turns a successful check into a failure.
modules="$(docker exec "$CONTAINER" frankenphp list-modules)"
grep -q 'http.handlers.wp_cache' <<< "$modules" \
    || fail "the wp_cache Caddy module is not registered"
grep -q 'http.encoders.br' <<< "$modules" \
    || fail "the brotli encoder is not registered"
pass "the wp_cache module and the brotli encoder are registered"

# The PHP extensions the image ships have to be loaded. opcache is a zend
# extension, so "php -m" reports it as "Zend OPcache".
php_modules="$(docker exec "$CONTAINER" php -m)"
for extension in bcmath exif gd imagick intl mysqli zip; do
    grep -qix "$extension" <<< "$php_modules" \
        || fail "the PHP extension ${extension} is not loaded"
done
grep -qix 'Zend OPcache' <<< "$php_modules" \
    || fail "the opcache zend extension is not loaded"
pass "all PHP extensions are loaded"

# The cache purge API has to answer.
status="$(docker exec "$CONTAINER" \
    curl -s -o /dev/null -w '%{http_code}' \
    -X POST -H 'X-WPSidekick-Purge-Key: smoke-test' \
    "http://localhost/__cache/purge/" || true)"
[ "$status" = "200" ] || fail "the cache purge API returned ${status} instead of 200"
pass "the cache purge API answers"

# Caddy has to serve the site. Without a database WordPress answers with a
# 500, but the request still has to reach PHP.
status="$(docker exec "$CONTAINER" \
    curl -s -o /dev/null -w '%{http_code}' http://localhost/ || true)"
[ "$status" != "000" ] || fail "Caddy did not answer the request"
pass "Caddy serves requests (HTTP ${status})"

echo "==> Smoke test passed for ${IMAGE}"
