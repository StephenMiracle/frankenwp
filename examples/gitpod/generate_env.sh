#!/bin/bash

# Generate the dynamic URL
url=$(gp url | awk -F"//" '{print $2}')
url="https://8100-$url/"

# Write to the .env file
cat <<EOL > .env
SERVER_NAME=:80
DB_HOST=db
DB_USER=exampleuser
DB_PASSWORD=examplepass
DB_NAME=exampledb
WP_DEBUG=true
DB_TABLE_PREFIX=wp_
CACHE_LOC=/var/www/html/wp-content/cache
TTL=80000
PURGE_PATH=/__cache/purge
PURGE_KEY=
BYPASS_HOME=false
BYPASS_PATH_PREFIXES=/wp-admin,/wp-content,/wp-includes,/wp-json,/feed
CACHE_RESPONSE_CODES=000
CADDY_GLOBAL_OPTIONS="email myemail@sample.com
auto_https disable_redirects
debug"
WP_SITEURL=$url
WP_HOME=$url
EOL
