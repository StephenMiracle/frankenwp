# FrankenPress Docker Image

A WordPress image built for simplicity and scale, powered by FrankenPHP and Caddy.

## Quick Start

```bash
docker run -d \
  -p 80:80 \
  -e DB_HOST=your-db-host \
  -e DB_USER=wordpress \
  -e DB_PASSWORD=your-password \
  -e DB_NAME=wordpress \
  notglossy/frankenpress:latest
```

## Available Images

### Standard Images
- `notglossy/frankenpress:latest` - Latest with Debian Trixie (amd64, arm64)
- `notglossy/frankenpress:php-8.4-trixie` - PHP 8.4 on Debian Trixie (amd64, arm64)
- `notglossy/frankenpress:php-8.4-bookworm` - PHP 8.4 on Debian Bookworm (amd64, arm64, arm/v7)
- `notglossy/frankenpress:php-8.3-trixie` - PHP 8.3 on Debian Trixie (amd64, arm64)
- `notglossy/frankenpress:php-8.3-bookworm` - PHP 8.3 on Debian Bookworm (amd64, arm64, arm/v7)
- `notglossy/frankenpress:php-8.2-trixie` - PHP 8.2 on Debian Trixie (amd64, arm64)
- `notglossy/frankenpress:php-8.2-bookworm` - PHP 8.2 on Debian Bookworm (amd64, arm64, arm/v7)

### VIPS Images (with FFI support for advanced image processing)
- `notglossy/frankenpress:vips-ffi` - Latest VIPS with Debian Trixie (amd64, arm64)
- `notglossy/frankenpress:php-8.4-vips-ffi-trixie` - PHP 8.4 VIPS on Debian Trixie (amd64, arm64)
- `notglossy/frankenpress:php-8.4-vips-ffi-bookworm` - PHP 8.4 VIPS on Debian Bookworm (amd64, arm64, arm/v7)

**Note:** ARM v7 (32-bit) support is only available with Debian Bookworm due to package availability limitations in Trixie.

## Choosing Between Trixie and Bookworm

### Debian Trixie (Recommended)
- **Testing Debian release** (currently testing, will become stable)
- Newer packages and features
- Available for: `linux/amd64`, `linux/arm64`
- Default for `:latest` tag
- Built on native ARM runners for faster builds

### Debian Bookworm
- **Current stable Debian release**
- More mature, wider package support
- Available for: `linux/amd64`, `linux/arm64`, `linux/arm/v7`
- **Required for 32-bit ARM (arm/v7)** devices like Raspberry Pi 2/3
- Built on native ARM runners for faster builds

Use Bookworm if you need ARM v7 support or prefer a more established base. Otherwise, use Trixie for the latest packages.

## Performance & Build Optimization

All ARM builds (arm64 and arm/v7) are built on native GitHub-hosted ARM runners (`ubuntu-24.04-arm`) for maximum performance and speed. This eliminates QEMU emulation overhead, resulting in significantly faster build times and better performance.

## Links

- [Docker Hub](https://hub.docker.com/r/notglossy/frankenpress)
- [GitHub Repository](https://github.com/notglossy/frankenpress)

## What's Included

### Core Components

- **[WordPress](https://wordpress.org/)** - Latest version from official WordPress Docker images
- **[FrankenPHP](https://frankenphp.dev/)** - Modern PHP application server (custom builds from [frankenpress-src](https://github.com/notglossy/frankenpress-src))
- **[Caddy](https://caddyserver.com/)** - Fast, secure web server with automatic HTTPS
- **PHP Extensions** - Optimized selection for WordPress performance

### PHP Extensions & Caching

**Performance & Caching:**
- OPcache (configured for production)
- APCu
- Memcache
- Memcached
- Redis
- igbinary
- msgpack

**WordPress Essentials:**
- bcmath
- exif
- gd
- intl
- mysqli
- zip
- imagick

**VIPS Images Only:**
- FFI (Foreign Function Interface)
- libvips (high-performance image processing)

### Environment Variables

#### FrankenPHP

- `SERVER_NAME`: change the addresses on which to listen, the provided hostnames will also be used for the generated TLS certificate
- `CADDY_GLOBAL_OPTIONS`: inject global options (debug most common)
- `FRANKENPHP_CONFIG`: inject config under the frankenphp directive

#### Wordpress

- `DB_NAME`: The WordPress database name.
- `DB_USER`: The WordPress database user.
- `DB_PASSWORD`: The WordPress database password.
- `DB_HOST`: The WordPress database host.
- `DB_TABLE_PREFIX`: The WordPress database table prefix.
- `WP_DEBUG`: Turns on WordPress Debug.
- `FORCE_HTTPS`: Tells WordPress to use https on requests. This is beneficial behind load balancer. Defaults to true.
- `WORDPRESS_CONFIG_EXTRA`: use this for adding WP_HOME, WP_SITEURL, etc

## Questions

### Why Not Just Use Standard WordPress Images?

The standard WordPress images are a good starting point and can handle many use cases, but require significant modification to scale. You also don't get FrankenPHP app server. Instead, you need to choose Apache or PHP-FPM. We use the WordPress base image but extend it with FrankenPHP & Caddy.

### Why FrankenPHP?

FrankenPHP is built on Caddy, a modern web server built in Go. It is secure & performs well when scaling becomes important. It also allows us to take advantage of built-in mature concurrency through goroutines into a single Docker image. high performance in a single lean image.

**[Check out FrankenPHP Here](https://frankenphp.dev/ "FrankenPHP")**

### Why is Non-Root User Important?

It is good practice to avoid using root users in your Docker images for security purposes. If a questionable individual gets access into your running Docker container with root account then they could have access to the cluster and all the resources it manages. This could be problematic. On the other hand, by creating a user specific to the Docker image, narrows the threat to only the image itself. It is also important to note that the base WordPress images also create non-root users by default.


### How to use when behind load balancer or proxy?

_tldr: Use a port (ie :80, :8095, etc) for SERVER_NAME env variable._

Working in cloud environments like AWS can be tricky because your traffic is going through a load balancer or some proxy. This means your server name is not what you think your server name is. Your domain hits a proxy dns entry that then hits your application. The application doesn't know your domain. It knows the proxied name. This may seem strange, but it's actually a well established strong architecture pattern.

What about SSL cert? Use `SERVER_NAME=mydomain.com, :80`
Caddy, the underlying application server is flexible enough for multiple entries. Separate multiple values with a comma. It will still request certificate.
