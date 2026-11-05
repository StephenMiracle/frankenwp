ARG WORDPRESS_VERSION=latest
ARG PHP_VERSION=8.5
# FrankenPHP 1.13.2 is the first release that ships the fixes for PHP2Shell
# (CVE-2026-109618 / CVE-2026-109619 - unauthenticated RCE) and for the
# FrankenPHP advisories GHSA-ccgp-ch9h-533f, GHSA-4gfw-9v29-gp9h,
# GHSA-fq24-r53r-xcx3 and GHSA-6q3j-62j9-f9hh.
# Override with --build-arg FRANKENPHP_VERSION=... , but never with a version
# older than 1.13.2 - the build fails below if the base image is too old.
ARG FRANKENPHP_VERSION=1.13.5
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

WORKDIR /go/src/app

COPY ./sidekick/middleware/cache ./cache
COPY ./sidekick/frankenphp_imports.go ./caddy/frankenphp/zz_frankenwp_imports.go

# CGO is required: FrankenPHP embeds the PHP runtime.
ENV CGO_ENABLED=1 \
    GOSUMDB=off

RUN set -eux; \
    cd /go/src/app/caddy; \
    # Point the build at the local sources instead of the module proxy.
    go mod edit \
        -replace github.com/dunglas/frankenphp=/go/src/app \
        -replace github.com/dunglas/frankenphp/caddy=/go/src/app/caddy \
        -replace github.com/prihlop/frankenwp/sidekick/middleware/cache=/go/src/app/cache; \
    go mod edit \
        -require=github.com/prihlop/frankenwp/sidekick/middleware/cache@v0.0.0; \
    cd /go/src/app/caddy/frankenphp; \
    CGO_CFLAGS="$(php-config --includes)" \
    CGO_LDFLAGS="$(php-config --ldflags) $(php-config --libs)" \
    go build \
        -ldflags="-w -s" \
        -tags=nobadger,nomysql,nopgx \
        -o /usr/local/bin/frankenphp .; \
    # Fail the build if the custom modules did not make it into the binary.
    # The module list is captured first: piping it straight into "grep -q"
    # makes grep close the pipe early, which kills the producer with SIGPIPE
    # and fails the build under "set -o pipefail".
    modules="$(/usr/local/bin/frankenphp list-modules)"; \
    echo "$modules" | grep -q 'http.handlers.wp_cache'; \
    echo "$modules" | grep -q 'http.encoders.br'; \
    # Caddy needs the capability to bind to port 80/443. It is set here so
    # that the final stage can copy the binary without losing the capability.
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp; \
    getcap /usr/local/bin/frankenphp


FROM dunglas/frankenphp:${FRANKENPHP_VERSION}-php$PHP_VERSION AS ext

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libicu-dev \
        libjpeg-dev \
        libmagickwand-dev \
        libonig-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

RUN set -eux; \
    install-php-extensions \
        bcmath \
        exif \
        gd \
        intl \
        mysqli \
        zip \
        imagick/imagick@3.8.1 \
        opcache; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/*

RUN set -eux; \
    cd /usr/local/lib/php/extensions/*/; \
    for so in *.so; do ldd "$so" 2>/dev/null; done \
        | grep -oE '/[^ ]+\.so[^ ]*' | sort -u \
        | while read -r lib; do readlink -f "$lib"; done | sort -u > /tmp/libs.txt; \
    : > /tmp/packages.txt; \
    while read -r lib; do \
        dpkg -S "$lib" 2>/dev/null \
            | grep -E '^[a-z0-9][^ ]*: ' | head -n1 | cut -d: -f1 \
            >> /tmp/packages.txt || true; \
    done < /tmp/libs.txt; \
    grep -v -- '-dev$' /tmp/packages.txt | sort -u > /tmp/runtime-packages.txt; \
    cat /tmp/runtime-packages.txt | tr '\n' ' '; echo


FROM wordpress:$WORDPRESS_VERSION AS wp
FROM dunglas/frankenphp:${FRANKENPHP_VERSION}-php$PHP_VERSION AS base

ARG USER=www-data
# Declared so that the WP_DEBUG line below does not trigger the
# "undefined variable" warning of the Dockerfile linter. The behaviour is
# unchanged: WP_DEBUG is only set when the build arg DEBUG is given.
ARG DEBUG

LABEL org.opencontainers.image.title=FrankenWP
LABEL org.opencontainers.image.description="Optimized WordPress containers to run everywhere. Built with FrankenPHP & Caddy."
LABEL org.opencontainers.image.source=https://github.com/prihlop/frankenwp
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="PRIHLOP"


# Replace the official binary by the one contained your custom modules.
#
# The capability to bind to port 80/443 is set on the binary in the builder
# stage already. A plain COPY would drop the file capabilities, and a
# "setcap" afterwards would copy the whole 58 MB binary into a second layer.
# Copying through a bind mount with "cp --preserve=xattr" keeps the
# capabilities and avoids the duplicate layer.
RUN --mount=from=builder,source=/usr/local/bin/frankenphp,target=/tmp/frankenphp \
    cp --preserve=xattr,mode /tmp/frankenphp /usr/local/bin/frankenphp && \
    getcap /usr/local/bin/frankenphp
ENV WP_DEBUG=${DEBUG:+1}
ENV FORCE_HTTPS=0
ENV PHP_INI_SCAN_DIR=$PHP_INI_DIR/conf.d

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ghostscript \
        git \
        libnss3-tools \
        unzip; \
    apt-get purge -y --auto-remove \
        libcurl4-openssl-dev \
        libjpeg-dev \
        libmemcached-dev \
        libonig-dev \
        libssl-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    # The toolchain that the base image ships for compiling extensions is not
    # needed at runtime either.
    apt-get purge -y --auto-remove \
        autoconf \
        bzip2 \
        dpkg-dev \
        file \
        g++ \
        gcc \
        libc-dev-bin \
        libc6-dev \
        libgcc-14-dev \
        make \
        pkg-config \
        re2c \
        xz-utils; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --from=ext /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=ext /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d/
COPY --from=ext /tmp/runtime-packages.txt /tmp/runtime-packages.txt
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        $(tr '\n' ' ' < /tmp/runtime-packages.txt); \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    rm -f /tmp/runtime-packages.txt

RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini
COPY php.ini $PHP_INI_DIR/conf.d/wp.ini

COPY --from=wp /usr/src/wordpress /usr/src/wordpress
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

RUN mkdir -p /var/www/html/wp-content && \
    chown ${USER}:${USER} /var/www/html/wp-content
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

# Caddy requires an additional capability to bind to port 80 and 443.
#
# The base image already ships the www-data user, so it is only created when
# it is missing (a custom USER build arg may point at a different account).
RUN set -eux; \
    if ! id -u ${USER} >/dev/null 2>&1; then \
        useradd --create-home --shell /usr/sbin/nologin ${USER}; \
    fi

# Caddy requires write access to /data/caddy and /config/caddy
RUN chown -R ${USER}:${USER} /data/caddy && \
    chown -R ${USER}:${USER} /config/caddy && \
    chown -R ${USER}:${USER} /var/www/html && \
    chown -R ${USER}:${USER} /usr/src/wordpress && \
    chown -R ${USER}:${USER} /usr/local/bin/docker-entrypoint.sh

USER $USER

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
