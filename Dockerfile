# Define build arguments that can be overridden at build time
ARG WORDPRESS_VERSION=latest
ARG PHP_VERSION=8.3

# First stage: builder - used to build FrankenPHP with custom modules
FROM dunglas/frankenphp:1.5-builder-php${PHP_VERSION}-bookworm AS builder

# Copy xcaddy tool from the official Caddy builder image
COPY --from=caddy:builder /usr/bin/xcaddy /usr/bin/xcaddy

# Set environment variables required for building FrankenPHP
# CGO must be enabled for C bindings, and set build flags for optimization
ENV CGO_ENABLED=1 XCADDY_SETCAP=1 XCADDY_GO_BUILD_FLAGS='-ldflags="-w -s" -trimpath'

# Allow Go toolchain auto-upgrade to handle newer Go version requirements
ENV GOTOOLCHAIN=auto

# Build FrankenPHP with xcaddy, including necessary modules
# --with allows adding external modules to the build
RUN xcaddy build \
    --output /usr/local/bin/frankenphp \
    --with github.com/dunglas/frankenphp=./ \
    --with github.com/dunglas/frankenphp/caddy=./caddy/ \
    --with github.com/dunglas/caddy-cbrotli
    # Add extra Caddy modules here

# Second stage: get WordPress files from the official WordPress image
FROM wordpress:$WORDPRESS_VERSION AS wp

# Third stage: final image based on FrankenPHP
FROM dunglas/frankenphp:1.5-php${PHP_VERSION}-bookworm AS base

# Add metadata labels to the image
LABEL org.opencontainers.image.title=FrankenPress
LABEL org.opencontainers.image.description="Optimized WordPress containers to run everywhere. Built with FrankenPHP & Caddy."
LABEL org.opencontainers.image.source=https://github.com/notglossy/frankenpress
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Not Glossy"


# Copy the custom-built FrankenPHP binary from the builder stage
COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp

# Set environment variables
ENV FORCE_HTTPS=0
ENV PHP_INI_SCAN_DIR=$PHP_INI_DIR/conf.d

# Install required system packages
# These packages are needed for PHP extensions and WordPress functionality
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
    libjpeg-dev \
    libwebp-dev \
    libzip-dev \
    libmemcached-dev \
    zlib1g-dev


# Install PHP extensions required by WordPress
# Using the install-php-extensions script from the base image
# You can find more at https://pecl.php.net
RUN install-php-extensions \
    bcmath \
    exif \
    gd \
    intl \
    mysqli \
    zip \
    imagick \
    opcache \
    memcache \
    memcached \
    apcu \
    redis \
    igbinary \
    msgpack

# Copy production PHP.ini and add WordPress-specific settings
RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini
COPY php.ini $PHP_INI_DIR/conf.d/wp.ini

# Copy WordPress files and configuration from the WordPress image
COPY --from=wp /usr/src/wordpress /usr/src/wordpress
COPY --from=wp /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d/
COPY --from=wp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/


# Configure PHP OpCache for better performance
# These settings are recommended for production WordPress sites
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
    { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=2'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini

# Configure PHP error logging
# These settings follow WordPress recommendations
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

RUN echo 'expose_php = Off' > $PHP_INI_DIR/conf.d/expose_php.ini

# Define a volume for WordPress files
VOLUME /var/www/html

# Set the working directory
WORKDIR /var/www/html

# Modify the WordPress Docker entrypoint script to work with FrankenPHP
RUN sed -i \
    -e 's/\[ "$1" = '\''php-fpm'\'' \]/\[\[ "$1" == frankenphp* \]\]/g' \
    -e 's/php-fpm/frankenphp/g' \
    /usr/local/bin/docker-entrypoint.sh

# Configure WordPress to support SSL and modify other WordPress settings
RUN sed -i 's/<?php/<?php if (!!getenv("FORCE_HTTPS")) { \$_SERVER["HTTPS"] = "on"; } define( "FS_METHOD", "direct" ); set_time_limit(300); /g' /usr/src/wordpress/wp-config-docker.php

# WordPress CLI installation (great for terminal access)
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp

# Copy Caddy server configuration
COPY Caddyfile /etc/caddy/Caddyfile

# Define the user that will run the container
# Default to www-data which is the standard web server user
#
# NOTE: On AWS, you may need to change this to root or modity the entrypoint script
# to chown volume mounts to this user as mounts are owned by root by default.
ARG USER_NAME=www-data

# Check if the user already exists, if not create it
# This prevents errors if we're using a different username
RUN if id "${USER_NAME}" &>/dev/null; then \
    echo "User ${USER_NAME} already exists"; \
else \
    useradd -m ${USER_NAME}; \
fi

# Set capabilities for FrankenPHP to bind to privileged ports (80/443)
# This is necessary to run as a non-root user
RUN setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp

# Create required directories and set proper ownership
# This ensures the web server can write to these locations
RUN chown -R ${USER_NAME}:${USER_NAME} /data/caddy && \
    chown -R ${USER_NAME}:${USER_NAME} /config/caddy && \
    chown -R ${USER_NAME}:${USER_NAME} /var/www/html && \
    chown -R ${USER_NAME}:${USER_NAME} /usr/src/wordpress && \
    chown -R ${USER_NAME}:${USER_NAME} /usr/local/bin/docker-entrypoint.sh

# Switch to non-root user for better security
USER $USER_NAME

ENV PAGER=more

# Define the entrypoint and default command
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
