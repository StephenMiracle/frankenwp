# WordPress + FrankenPHP Docker Image

An enterprise-grade WordPress image built for scale. It uses the new FrankenPHP server bundled with Caddy. Lightning-fast server side caching Caddy module.

## Getting Started

- [Docker Images](https://hub.docker.com/r/prihlop/frankenwp "Docker Hub")

### Examples

- [Standard environment with MariaDB & Docker Compose](./examples/basic/compose.yaml)
- [Debug with XDebug & Docker Compose](./examples/debug/compose.yaml)
- [SQLite with Docker Compose](./examples/sqlite/compose.yaml)

## Whats Included

### Build Arguments

- `FRANKENPHP_VERSION`: the FrankenPHP release to build on, pinned in [Dockerfile](./Dockerfile).
  The minimum supported version is `1.13.2`, the first release that ships the fixes for PHP2Shell (`CVE-2026-109618` / `CVE-2026-109619`,
  unauthenticated RCE) and for the FrankenPHP advisories `GHSA-ccgp-ch9h-533f`,
  `GHSA-4gfw-9v29-gp9h`, `GHSA-fq24-r53r-xcx3` and `GHSA-6q3j-62j9-f9hh`. The build fails
  if the resolved base image is older than `1.13.2`.
- `PHP_VERSION`: the PHP version of the base image. Defaults to `8.4`.
- `WORDPRESS_VERSION`: the WordPress version of the base image. Defaults to `latest`.
- `USER`: the unprivileged user the server runs as. Defaults to `www-data`.

### Automatic FrankenPHP updates

The `Update FrankenPHP` workflow checks the latest stable GitHub release daily at
06:17 UTC and can also be started from **Actions → Update FrankenPHP → Run workflow**.
It proposes upgrades only, skips prereleases, and creates or updates a single PR
on `automation/update-frankenphp`. Merging remains manual.

The Dockerfile is the source of the version for all CI builds; the repository
variable `FRANKENPHP_VERSION` is no longer used. Local builds can still override it
with `--build-arg FRANKENPHP_VERSION=...`. The security floor stays at `1.13.2`.

To enable PR creation, merge the workflow into the default branch and enable
**Settings → Actions → General → Workflow permissions → Allow GitHub Actions to
create and approve pull requests**.

For automatic PR build and smoke-test runs, add the repository secret
`FRANKENPHP_UPDATE_TOKEN`: a fine-grained personal access token with **Contents**
and **Pull requests** read/write access to this repository. Without this secret,
the workflow uses `GITHUB_TOKEN` and still creates PRs, but GitHub does not trigger
PR workflows for those events. Close and reopen such a PR manually to start checks.
See the [action's token documentation](https://github.com/peter-evans/create-pull-request#token).

### Services

- [WordPress](https://hub.docker.com/_/wordpress "WordPress Docker Image")
- [FrankenPHP](https://hub.docker.com/r/dunglas/frankenphp "FrankenPHP Docker Image")
- [Caddy](https://caddyserver.com/ "Caddy Server")

### Caching

- opcache
- Internal server sidekick

### Environment Variables

#### FrankenPHP

- `SERVER_NAME`: change the addresses on which to listen, the provided hostnames will also be used for the generated TLS certificate
- `CADDY_GLOBAL_OPTIONS`: inject global options (debug most common)
- `FRANKENPHP_CONFIG`: inject config under the frankenphp directive

#### Sidekick Cache

- `CACHE_LOC`: Where to store cache. Defaults to /var/www/html/wp-content/cache
- `CACHE_RESPONSE_CODES`: Which status codes to cache. Defaults to 200,404,405
- `BYPASS_PATH_PREFIXES`: Which path prefixes to not cache. Defaults to /wp-admin,/wp-json
- `BYPASS_HOME`: Whether to skip caching home. Defaults to false.
- `PURGE_KEY`: Create a purge key that must be validated on purge requests. Helps to prevent malicious intent. No default.
- `PURGE_PATH`: Create a custom route for the cache purge API path. Defaults to /\_\_cache/purge.
- `TTL`: Defines how long objects should be stored in cache. Defaults to 6000.

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

### What are the Changes from Base FrankenPHP?

This custom Caddy build also includes an internal project named sidekick. It provides lightning fast cache that can be distributed among many containers. The default cache uses the local wp-content/cache directory but can use many cache services.

### How to use when behind load balancer or proxy?

_tldr: Use a port (ie :80, :8095, etc) for SERVER_NAME env variable._

Working in cloud environments like AWS can be tricky because your traffic is going through a load balancer or some proxy. This means your server name is not what you think your server name is. Your domain hits a proxy dns entry that then hits your application. The application doesn't know your domain. It knows the proxied name. This may seem strange, but it's actually a well established strong architecture pattern.

What about SSL cert? Use `SERVER_NAME=mydomain.com, :80`
Caddy, the underlying application server is flexible enough for multiple entries. Separate multiple values with a comma. It will still request certificate.

## License

This project is licensed under the [MIT License](./LICENSE).
