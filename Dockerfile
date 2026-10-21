ARG WORDPRESS_VERSION=latest
ARG PHP_VERSION=8.4
# FrankenPHP 1.13.2 is the first release that ships the fixes for PHP2Shell
# (CVE-2026-109618 / CVE-2026-109619 - unauthenticated RCE) and for the
# FrankenPHP advisories GHSA-ccgp-ch9h-533f, GHSA-4gfw-9v29-gp9h,
# GHSA-fq24-r53r-xcx3 and GHSA-6q3j-62j9-f9hh.
# Override with --build-arg FRANKENPHP_VERSION=... , but never with a version
# older than 1.13.2 - the build fails below if the base image is too old.
ARG FRANKENPHP_VERSION=1.13.2
ARG USER=www-data



FROM dunglas/frankenphp:${FRANKENPHP_VERSION}-builder-php$PHP_VERSION AS builder

# Refuse to build on a FrankenPHP release that is still affected by the
# PHP2Shell / FrankenPHP advisories. The base image ships the version in
# CGO_CFLAGS (-DFRANKENPHP_VERSION=...), so it is the authoritative value.
RUN set -eux; \
    fp_version="$(printf '%s' "$CGO_CFLAGS" | sed -n 's/.*-DFRANKENPHP_VERSION=\([^ ]*\).*/\1/p')"; \
    fp_version="${fp_version#v}"; \
    echo "Building against FrankenPHP ${fp_version}"; \
    case "$fp_version" in \
        dev|*dev*) echo "Refusing to build against a development FrankenPHP build"; exit 1 ;; \
    esac; \
    if [ "$(printf '%s\n' "1.13.2" "$fp_version" | sort -V | head -n1)" != "1.13.2" ]; then \
        echo "ERROR: FrankenPHP ${fp_version} is older than 1.13.2 and is affected by"; \
        echo "       CVE-2026-109618 / CVE-2026-109619 (PHP2Shell) and the"; \
        echo "       GHSA-ccgp-ch9h-533f / GHSA-4gfw-9v29-gp9h /"; \
        echo "       GHSA-fq24-r53r-xcx3 / GHSA-6q3j-62j9-f9hh advisories."; \
        echo "       Bump FRANKENPHP_VERSION to at least 1.13.2."; \
        exit 1; \
    fi

# Copy xcaddy in the builder image
COPY --from=caddy:builder /usr/bin/xcaddy /usr/bin/xcaddy

COPY ./sidekick/middleware/cache ./cache
COPY ./sidekick/middleware/cache/fetch-go-modules.sh /usr/local/bin/fetch-go-modules.sh
RUN chmod +x /usr/local/bin/fetch-go-modules.sh

# GOSUMDB=off avoids failing on transient sum.golang.org resets; the module
# versions are still pinned by the go.sum shipped in the builder image.
#
# The Go proxy sometimes resets the connection while downloading the larger
# module archives, and Go does not retry a half-written archive. The build is
# therefore retried, and the archive of every module that failed to download
# is re-fetched with range requests before the next attempt.
RUN set -eu; \
    for attempt in 1 2 3 4 5 6 7 8; do \
        build_log="/tmp/xcaddy-build.log"; \
        if CGO_ENABLED=1 \
            GOFLAGS="-mod=mod" \
            GOSUMDB=off \
            XCADDY_GO_BUILD_FLAGS="-ldflags='-w -s' -tags=nobadger,nomysql,nopgx" \
            CGO_CFLAGS="$(php-config --includes)" \
            CGO_LDFLAGS="$(php-config --ldflags) $(php-config --libs)" \
            xcaddy build \
            --output /usr/local/bin/frankenphp \
            --with github.com/dunglas/frankenphp=./ \
            --with github.com/dunglas/frankenphp/caddy=./caddy/ \
            --with github.com/dunglas/caddy-cbrotli \
            # Add extra Caddy modules here
            --with github.com/prihlop/frankenwp/sidekick/middleware/cache=./cache > "$build_log" 2>&1; then \
            cat "$build_log"; \
            break; \
        fi; \
        cat "$build_log"; \
        if [ "$attempt" = "8" ]; then \
            echo "ERROR: xcaddy build failed after ${attempt} attempts"; \
            exit 1; \
        fi; \
        echo ">>> xcaddy build failed (attempt ${attempt}), re-fetching the modules that could not be downloaded"; \
        fetch_args=""; \
        for mv in $(grep -oE '[a-zA-Z0-9._~/-]+@v[0-9][a-zA-Z0-9.+-]*: (read|Get) "https://proxy\.golang\.org/' "$build_log" \
            | sed -E 's/: (read|Get) "https:\/\/proxy\.golang\.org\// /' \
            | tr ' ' '\n' | grep '@' | sort -u); do \
            fetch_args="${fetch_args} ${mv%@*} ${mv#*@}"; \
        done; \
        if [ -n "$fetch_args" ]; then \
            # shellcheck disable=SC2086 \
            fetch-go-modules.sh $fetch_args || true; \
        fi; \
        sleep 3; \
    done; \
    /usr/local/bin/frankenphp version


FROM wordpress:$WORDPRESS_VERSION AS wp
FROM dunglas/frankenphp:${FRANKENPHP_VERSION}-php$PHP_VERSION AS base

LABEL org.opencontainers.image.title=FrankenWP
LABEL org.opencontainers.image.description="Optimized WordPress containers to run everywhere. Built with FrankenPHP & Caddy."
LABEL org.opencontainers.image.url=https://wpeverywhere.com
LABEL org.opencontainers.image.source=https://github.com/StephenMiracle/frankenwp
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Stephen Miracle"


# Replace the official binary by the one contained your custom modules
COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
ENV WP_DEBUG=${DEBUG:+1}
ENV FORCE_HTTPS=0
ENV PHP_INI_SCAN_DIR=$PHP_INI_DIR/conf.d


# The apt archives are removed right after the install: they are large and the
# layer is kept in the build cache, so leaving them behind bloats the image
# and the disk usage of every subsequent build.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    ghostscript \
    git \
    libcurl4-openssl-dev \
    libjpeg-dev \
    libmemcached-dev \
    libnss3-tools \
    libonig-dev \
    libssl-dev \
    libwebp-dev \
    libxml2-dev \
    libzip-dev \
    libzip-dev \
    unzip \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*


# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
RUN install-php-extensions \
    bcmath \
    exif \
    gd \
    intl \
    mysqli \
    zip \
    # See https://github.com/Imagick/imagick/issues/640#issuecomment-2077206945
    imagick/imagick@master \
    opcache \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/*


RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini
COPY php.ini $PHP_INI_DIR/conf.d/wp.ini

COPY --from=wp /usr/src/wordpress /usr/src/wordpress
COPY --from=wp /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d/
COPY --from=wp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/


# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
    { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=2'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
    # https://www.php.net/manual/en/errorfunc.constants.php
    # https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
    echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
    echo 'display_errors = Off'; \
    echo 'display_startup_errors = Off'; \
    echo 'log_errors = On'; \
    echo 'error_log = /dev/stderr'; \
    echo 'log_errors_max_len = 1024'; \
    echo 'ignore_repeated_errors = On'; \
    echo 'ignore_repeated_source = Off'; \
    echo 'html_errors = Off'; \
    } > $PHP_INI_DIR/conf.d/error-logging.ini


WORKDIR /var/www/html

VOLUME /var/www/html/wp-content


COPY wp-content/mu-plugins /usr/src/wordpress/wp-content/mu-plugins
RUN mkdir -p /usr/src/wordpress/wp-content/cache



# Patch the upstream WordPress entrypoint so it takes the php-fpm branch when
# the command is "frankenphp" (the official image only knows apache2/php-fpm).
# The upstream wording changes over time, so the patch is verified afterwards
# and fails the build instead of silently leaving WordPress uncopied.
RUN set -eux; \
    sed -i \
        -e 's/\[ "${1-}" = '\''php-fpm'\'' \]/\[\[ "${1-}" == frankenphp* \]\]/g' \
        -e 's/\[ "$1" = '\''php-fpm'\'' \]/\[\[ "$1" == frankenphp* \]\]/g' \
        -e 's/php-fpm/frankenphp/g' \
        /usr/local/bin/docker-entrypoint.sh; \
    if ! grep -q 'frankenphp' /usr/local/bin/docker-entrypoint.sh; then \
        echo "ERROR: failed to patch docker-entrypoint.sh for frankenphp."; \
        echo "       The upstream WordPress entrypoint changed shape again;"; \
        echo "       update the sed expressions above."; \
        exit 1; \
    fi; \
    grep -n 'frankenphp' /usr/local/bin/docker-entrypoint.sh



# Add $_SERVER['ssl'] = true; when env USE_SSL = true is set to the wp-config.php file here: /usr/local/bin/wp-config-docker.php
RUN set -eux; \
    sed -i 's/<?php/<?php if (!!getenv("FORCE_HTTPS")) { \$_SERVER["HTTPS"] = "on"; } define( "FS_METHOD", "direct" ); set_time_limit(300); /g' /usr/src/wordpress/wp-config-docker.php; \
    if ! grep -q 'FORCE_HTTPS' /usr/src/wordpress/wp-config-docker.php; then \
        echo "ERROR: failed to patch wp-config-docker.php."; \
        exit 1; \
    fi

# Adding WordPress CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp

COPY Caddyfile /etc/caddy/Caddyfile

# Caddy requires an additional capability to bind to port 80 and 443
RUN useradd -D ${USER} && \
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp

# Caddy requires write access to /data/caddy and /config/caddy
RUN chown -R ${USER}:${USER} /data/caddy && \
    chown -R ${USER}:${USER} /config/caddy && \
    chown -R ${USER}:${USER} /var/www/html && \
    chown -R ${USER}:${USER} /usr/src/wordpress && \
    chown -R ${USER}:${USER} /usr/local/bin/docker-entrypoint.sh

USER $USER

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
