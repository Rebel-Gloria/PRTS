#!/bin/bash
set -euo pipefail
# Rebuild and replay exact product sources, then run the core tests.
exec bash "$(dirname "$0")/run_product.sh" final "${1:?Pass the diagnostic capture directory}"
