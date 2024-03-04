ARG WORDPRESS_VERSION=latest
ARG PHP_VERSION=8.3
ARG USER=www-data

FROM wordpress:$WORDPRESS_VERSION as wp

FROM dunglas/frankenphp:latest-php${PHP_VERSION} AS base
ENV CADDY_GLOBAL_OPTIONS=${DEBUG:+debug}
ENV WP_DEBUG=${DEBUG:+1}
ENV FORCE_HTTPS=0
ENV PHP_INI_SCAN_DIR=$PHP_INI_DIR/conf.d


RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    ghostscript \
    curl \
    libonig-dev \
    libxml2-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libzip-dev \
    unzip \
    git \
    libmagickwand-dev \
    libjpeg-dev \
    libwebp-dev \
    libzip-dev \
    libmagickcore-dev \
    libmagickwand-6.q16-6 \
    libmagickcore-6.q16-6 \
    libmemcached-dev \
    zlib1g-dev

# https://pecl.php.net/package/imagick
RUN set -ex; pecl install imagick-3.6.0; \
    docker-php-ext-enable imagick; \
    rm -r /tmp/pear; 


RUN docker-php-ext-configure gd \
    --with-freetype \
    --with-jpeg \
    --with-webp

RUN	docker-php-ext-install -j "$(nproc)" \
    bcmath \
    exif \
    gd \
    intl \
    mysqli \
    zip 


RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini
COPY --from=composer/composer:latest-bin /composer /usr/bin/composer


COPY --from=wp /usr/src/wordpress /usr/src/wordpress
COPY --from=wp /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d/
COPY --from=wp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
    docker-php-ext-enable opcache; \
    { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=2'; \
    echo 'opcache.jit_buffer_size=100M'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini


## Installing REDIS
RUN pecl install redis \
    && rm -rf /tmp/pear \
    && docker-php-ext-enable redis

## Installing Memcached
RUN pecl install memcached-3.2.0 \
    && docker-php-ext-enable memcached


# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
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

VOLUME /var/www/html

COPY Caddyfile /etc/caddy/Caddyfile

RUN sed -i \
    -e 's/\[ "$1" = '\''php-fpm'\'' \]/\[\[ "$1" == frankenphp* \]\]/g' \
    -e 's/php-fpm/frankenphp/g' \
    /usr/local/bin/docker-entrypoint.sh



RUN useradd -D ${USER} && \
    # Caddy requires an additional capability to bind to port 80 and 443
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp
# Caddy requires write access to /data/caddy and /config/caddy


# Add $_SERVER['ssl'] = true; when env USE_SSL = true is set to the wp-config.php file here: /usr/local/bin/wp-config-docker.php
RUN sed -i 's/<?php/<?php if (!!getenv("FORCE_HTTPS")) { \$_SERVER["HTTPS"] = "on"; }/g' /usr/src/wordpress/wp-config-docker.php


RUN chown -R ${USER}:${USER} /data/caddy && \
    chown -R ${USER}:${USER} /config/caddy && \
    chown -R ${USER}:${USER} /var/www/html && \
    chown -R ${USER}:${USER} /usr/src/wordpress && \
    chown -R ${USER}:${USER} /usr/local/bin/docker-entrypoint.sh

USER $USER

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]

