# =============================================================================
# FrankenPress - Optimized WordPress Docker Image
# =============================================================================
# This Dockerfile creates a production-ready WordPress container using:
# - FrankenPHP: A modern PHP application server written in Go
# - Caddy: An automatic HTTPS server with integrated reverse proxy
# - WordPress: The world's most popular CMS
#
# The image is optimized for:
# - Minimal layers (better caching and smaller image size)
# - Layer ordering based on change frequency (faster rebuilds)
# - Security (runs as non-root user)
# - Performance (OpCache, APCu, OPcache optimizations)
# =============================================================================

# -----------------------------------------------------------------------------
# Build Arguments
# -----------------------------------------------------------------------------
# These can be overridden at build time using --build-arg
# Example: docker build --build-arg PHP_VERSION=8.2 .
ARG WORDPRESS_VERSION=latest
ARG PHP_VERSION=8.3
ARG DEBIAN_VERSION=trixie

# -----------------------------------------------------------------------------
# Stage 1: WordPress Source Files
# -----------------------------------------------------------------------------
# Pull WordPress core files from the official WordPress Docker image
# This stage is used only to extract files, not run WordPress
FROM public.ecr.aws/docker/library/wordpress:$WORDPRESS_VERSION AS wp

# -----------------------------------------------------------------------------
# Stage 2: Final FrankenPress Image
# -----------------------------------------------------------------------------
# Base image uses custom FrankenPHP builds from ghcr.io/notglossy/frankenpress-src
# Format: php{VERSION}-{DEBIAN_VERSION}-{ARCH}
FROM ghcr.io/notglossy/frankenpress-src:php${PHP_VERSION}-${DEBIAN_VERSION} AS base

# -----------------------------------------------------------------------------
# Metadata Labels
# -----------------------------------------------------------------------------
# OCI-compliant image labels for container registries and tooling
# See: https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title=FrankenPress \
      org.opencontainers.image.description="Optimized WordPress containers to run everywhere. Built with FrankenPHP & Caddy." \
      org.opencontainers.image.source=https://github.com/notglossy/frankenpress \
      org.opencontainers.image.licenses=MIT \
      org.opencontainers.image.vendor="Not Glossy"

# -----------------------------------------------------------------------------
# Environment Variables
# -----------------------------------------------------------------------------
# FORCE_HTTPS: Set to 1 to force HTTPS in WordPress (sets $_SERVER['HTTPS'])
# PHP_INI_SCAN_DIR: Directory for additional PHP configuration files
# PAGER: Default pager for terminal sessions (useful for WP-CLI)
ENV FORCE_HTTPS=0 \
    PHP_INI_SCAN_DIR=$PHP_INI_DIR/conf.d \
    PAGER=more

# -----------------------------------------------------------------------------
# System Dependencies and PHP Extensions
# -----------------------------------------------------------------------------
# Combined into a single layer to minimize image size and improve build cache.
# This layer installs runtime and build dependencies, compiles PHP extensions,
# then removes build-only dependencies to reduce final image size.
#
# Runtime packages (kept in final image):
# - ca-certificates: SSL/TLS certificate validation
# - ghostscript: PDF generation and manipulation
# - curl: HTTP client for WP-CLI and downloads
# - unzip: Archive extraction
# - git: Version control (useful for plugin/theme development)
# - lib* (non-dev): Runtime libraries for PHP extensions
#
# Build-only packages (removed after extensions are built):
# - *-dev: Development headers needed to compile PHP extensions
#
# PHP extensions installed via install-php-extensions script:
# - bcmath: Arbitrary precision mathematics (WooCommerce, etc.)
# - exif: Image metadata extraction
# - gd: Image manipulation library
# - intl: Internationalization support
# - mysqli: MySQL database driver
# - zip: Archive handling
# - imagick: Advanced image processing (alternative to GD)
# - opcache: Bytecode caching for performance
# - memcache/memcached: Object caching backends
# - apcu: In-memory user cache
# - redis: Object caching and sessions
# - igbinary/msgpack: Efficient serialization for caching
#
# See: https://github.com/mlocati/docker-php-extension-installer
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    ghostscript \
    curl \
    unzip \
    git \
    # Build dependencies (will be removed later)
    libonig-dev \
    libxml2-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libzip-dev \
    libjpeg-dev \
    libwebp-dev \
    zlib1g-dev \
    && install-php-extensions \
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
        msgpack \
    # Remove build dependencies to reduce image size
    && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
        libonig-dev \
        libxml2-dev \
        libcurl4-openssl-dev \
        libssl-dev \
        libzip-dev \
        libjpeg-dev \
        libwebp-dev \
        zlib1g-dev \
    # Clean up additional bloat
    && rm -rf /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/share/doc/* \
        /usr/share/man/*

# -----------------------------------------------------------------------------
# PHP Configuration
# -----------------------------------------------------------------------------
# Consolidated into a single layer to reduce image size.
#
# 1. Base PHP.ini: Start with production-recommended settings
# 2. OpCache settings: Configure bytecode caching for performance
#    - memory_consumption: 128MB for caching compiled scripts
#    - interned_strings_buffer: 8MB for string interning
#    - max_accelerated_files: Cache up to 4000 files
#    - revalidate_freq: Check for changes every 2 seconds
#    See: https://www.php.net/manual/en/opcache.configuration.php
#
# 3. Error logging: Production-safe error handling
#    - Errors logged to stderr for container log aggregation
#    - Display errors disabled for security
#    - Comprehensive error reporting enabled
#    See: https://github.com/docker-library/wordpress/issues/420
#
# 4. Security: Hide PHP version from HTTP headers
RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini \
    && { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=2'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini \
    && { \
        echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
        echo 'display_errors = Off'; \
        echo 'display_startup_errors = Off'; \
        echo 'log_errors = On'; \
        echo 'error_log = /dev/stderr'; \
        echo 'log_errors_max_len = 1024'; \
        echo 'ignore_repeated_errors = On'; \
        echo 'ignore_repeated_source = Off'; \
        echo 'html_errors = Off'; \
    } > $PHP_INI_DIR/conf.d/error-logging.ini \
    && echo 'expose_php = Off' > $PHP_INI_DIR/conf.d/expose_php.ini

# -----------------------------------------------------------------------------
# WP-CLI Installation
# -----------------------------------------------------------------------------
# WordPress Command Line Interface for managing WordPress from the terminal.
# Useful for plugin/theme management, database operations, and automation.
# See: https://wp-cli.org/
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# -----------------------------------------------------------------------------
# WordPress Core Files
# -----------------------------------------------------------------------------
# Copy WordPress core files and configuration from the official WordPress image.
# This includes:
# - /usr/src/wordpress: WordPress core files (copied to /var/www/html on start)
# - PHP configuration from WordPress image
# - docker-entrypoint.sh: WordPress initialization script
COPY --from=wp /usr/src/wordpress /usr/src/wordpress
COPY --from=wp /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d/
COPY --from=wp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/

# -----------------------------------------------------------------------------
# WordPress and Entrypoint Customization
# -----------------------------------------------------------------------------
# Modify the WordPress Docker entrypoint to work with FrankenPHP instead of PHP-FPM.
# Also inject WordPress configuration:
# - FORCE_HTTPS support: Enables HTTPS when FORCE_HTTPS env var is set
# - FS_METHOD=direct: Direct filesystem access (no FTP needed)
# - set_time_limit(300): Allow long-running operations (imports, updates, etc.)
RUN sed -i \
        -e 's/\[ "$1" = '\''php-fpm'\'' \]/\[\[ "$1" == frankenphp* \]\]/g' \
        -e 's/php-fpm/frankenphp/g' \
        /usr/local/bin/docker-entrypoint.sh \
    && sed -i 's/<?php/<?php if (!!getenv("FORCE_HTTPS")) { \$_SERVER["HTTPS"] = "on"; } define( "FS_METHOD", "direct" ); set_time_limit(300); /g' /usr/src/wordpress/wp-config-docker.php

# -----------------------------------------------------------------------------
# Custom Configuration Files
# -----------------------------------------------------------------------------
# These files are copied last as they're most likely to change during development.
# Placing them here maximizes Docker build cache efficiency.
#
# - php.ini: WordPress-specific PHP settings (upload size, execution time, etc.)
# - Caddyfile: Caddy web server configuration (routing, headers, compression)
COPY php.ini $PHP_INI_DIR/conf.d/wp.ini
COPY Caddyfile /etc/caddy/Caddyfile

# -----------------------------------------------------------------------------
# User and Permissions Setup
# -----------------------------------------------------------------------------
# Configure the container to run as a non-root user for security.
# This layer must come after all file copies to set proper ownership.
#
# Steps:
# 1. Create user if it doesn't exist (default: www-data)
# 2. Grant FrankenPHP permission to bind to ports 80/443 without root
# 3. Set ownership of all WordPress and Caddy directories
#
# NOTE: On some platforms (e.g., AWS ECS), volume mounts are owned by root.
# You may need to use USER_NAME=root or modify the entrypoint to chown volumes.
ARG USER_NAME=www-data

RUN if id "${USER_NAME}" &>/dev/null; then \
        echo "User ${USER_NAME} already exists"; \
    else \
        useradd -m ${USER_NAME}; \
    fi \
    && setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp \
    && chown -R ${USER_NAME}:${USER_NAME} /data/caddy \
        /config/caddy \
        /var/www/html \
        /usr/src/wordpress \
        /usr/local/bin/docker-entrypoint.sh

# -----------------------------------------------------------------------------
# Container Runtime Configuration
# -----------------------------------------------------------------------------
# Define persistent volume mount point for WordPress files
VOLUME /var/www/html

# Set working directory for all subsequent commands and container shell access
WORKDIR /var/www/html

# Switch to non-root user (all subsequent commands run as this user)
USER $USER_NAME

# -----------------------------------------------------------------------------
# Entrypoint and Command
# -----------------------------------------------------------------------------
# Entrypoint: WordPress initialization script (copies core files, sets up db)
# Command: Start FrankenPHP server with Caddy configuration
#
# The entrypoint handles:
# - Copying WordPress core files to /var/www/html if not present
# - Generating wp-config.php from environment variables
# - Database connection and installation
#
# To override the command (e.g., for debugging):
# docker run -it frankenpress bash
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
