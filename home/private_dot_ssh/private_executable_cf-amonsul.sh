#!/bin/zsh
# ssh's ProxyCommand for amonsul: cloudflared carries the session through the
# Cloudflare Tunnel, showing Access the service token from the Keychain. The
# token goes in the environment, never on a command line. cf-token stores it.
set -euo pipefail
CF=/opt/homebrew/bin/cloudflared
[[ -x $CF ]] || CF=/usr/local/bin/cloudflared
export TUNNEL_SERVICE_TOKEN_ID="$(/usr/bin/security find-generic-password -s cf-access-amonsul -a id -w)"
export TUNNEL_SERVICE_TOKEN_SECRET="$(/usr/bin/security find-generic-password -s cf-access-amonsul -a secret -w)"
exec "$CF" access ssh --hostname "$1"
