// This file is injected into the FrankenPHP Caddy `main` package during the
// Docker build. It registers the extra Caddy modules of this repository.
//
// The module is imported through the repository path
// (github.com/prihlop/frankenwp/sidekick/middleware/cache) even though the
// nested Go module declares a different module name; the Docker build wires
// the two together with a `replace` directive.
package main

import (
	// Brotli encoder, used by the `encode br zstd gzip` directive of the
	// bundled Caddyfile.
	_ "github.com/dunglas/caddy-cbrotli"

	// The wp_cache Caddy middleware of this repository.
	_ "github.com/prihlop/frankenwp/sidekick/middleware/cache"
)
