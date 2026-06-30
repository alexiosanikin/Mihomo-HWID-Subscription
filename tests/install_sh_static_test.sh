#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_SH="$REPO_DIR/install.sh"

require_pattern() {
  pattern="$1"
  message="$2"

  if ! grep -Eq "$pattern" "$INSTALL_SH"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

reject_pattern() {
  pattern="$1"
  message="$2"

  if grep -Eq "$pattern" "$INSTALL_SH"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require_pattern 'ensure_xkeen_mihomo\(\)' "install.sh must bootstrap XKeen when it is missing"
require_pattern 'xkeen_is_installed\(\)' "install.sh must detect an existing XKeen install"
require_pattern 'install_xkeen_distribution\(\)' "install.sh must install the XKeen distribution directly"
require_pattern 'install_xkeen_packages\(\)' "install.sh must install required XKeen packages before offline setup"
require_pattern 'download_mihomo_binary\(\)' "install.sh must download Mihomo for the router architecture"
require_pattern 'xkeen -io' "install.sh must use XKeen offline install to avoid geofile and cron prompts"
require_pattern 'xkeen_run -mihomo' "install.sh must switch an existing XKeen install to Mihomo when possible"
require_pattern 'XKEEN_FOREGROUND=1' "xkeen calls from install.sh must remain synchronous"
reject_pattern 'xkeen -i([[:space:]]|$)' "install.sh must not use XKeen full interactive install"

echo "install.sh static checks passed"
