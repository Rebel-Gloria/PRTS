#!/bin/zsh
set -euo pipefail
# Third-round default: rebuild and replay exact product sources, then run ALL core tests.
exec zsh "${0:A:h}/run_product.sh" final "${1:-/private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/diag/pull-17pm-1028}"
