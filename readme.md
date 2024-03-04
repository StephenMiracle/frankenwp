# WordPress + FrankenPHP Docker Image

An enterprise-grade WordPress image built for scale. It uses the new FrankenPHP server bundled with Caddy. Lightning-fast automated caching is provided through the cache-handler Caddy module. Default is set to local wp-content/cache location but can switch to other distributed options such as Redis if desired.

## Whats Included

### Services

- [WordPress](https://hub.docker.com/_/wordpress "WordPress Docker Image")
- [FrankenPHP](https://hub.docker.com/r/dunglas/frankenphp "FrankenPHP Docker Image")
- [Caddy](https://caddyserver.com/ "Caddy Server")

### Caching

- opcache
- cache-handler CaddyModule

### Environment Variables

- DEBUG // Flag to set WP_DEBUG & debug mode on server. (1 or 0)
- SERVER_NAME // Domain to set. Will request a SSL cert for it. Can also set to a port like :80, :8095
- DB_NAME
- DB_USER
- DB_PASSWORD
- DB_HOST
- DB_ROOT_PASSWORD
- DB_TABLE_PREFIX
- WP_DEBUG
- DEBUG
- WP_VERSION
- FORCE_HTTPS
- WORDPRESS_CONFIG_EXTRA // use this for adding CACHE, WP_HOME, WP_SITEURL, etc

This image copies content from the base WordPress image. Relevant environment variables can be found in the parent repository.

[Click here for the standard WordPress Docker Repo.](https://hub.docker.com/_/wordpress "WordPress Docker Images")

## Questions

### Why Not Just Use Standard WordPress Images?

The standard WordPress images are a good starting point and can handle many use cases, but require significant modification to scale. You also don't get FrankenPHP app server. Instead, you need to choose Apache or PHP-FPM. We use the WordPress base image but extend it with FrankenPHP & Caddy.

### Why FrankenPHP?

FrankenPHP is built on Caddy, a modern web server built in Go. It is secure & performs well when scaling becomes important. It also allows us to take advantage of built-in mature concurrency through goroutines into a single Docker image. high performance in a single lean image.

**[Check out FrankenPHP Here](https://frankenphp.dev/ "FrankenPHP")**

### Why is Non-Root User Important?

It is good practice to avoid using root users in your Docker images for security purposes. If a questionable individual gets access into your running Docker container with root account then they could have access to the cluster and all the resources it manages. This could be problematic. On the other hand, by creating a user specific to the Docker image, narrows the threat to only the image itself. It is also important to note that the base WordPress images also create non-root users by default.

### What are the Changes from Base FrankenPHP?

This custom FrankenPHP build includes the cache-handler Caddy module. It leverages the popular Souin HTTP cache service. It provides lightning fast cache that can be distributed among many containers. The default cache uses the local wp-content/cache directory but can use many cache services.

### How to use when behind load balancer or proxy?

_tldr: Use a port (ie :80, :8095, etc) for SERVER_NAME env variable._

Working in cloud environments like AWS can be tricky because your traffic is going through a load balancer or some proxy. This means your server name is not what you think your server name is. Your domain hits a proxy dns entry that then hits your application. The application doesn't know your domain. It knows the proxied name. This may seem strange, but it's actually a well established strong architecture pattern.

What about SSL cert? Use `SERVER_NAME=mydomain.com, :80`
Caddy, the underlying application server is flexible enough for multiple entries. Separate multiple values with a comma. It will still request certificate.
