#!/usr/bin/env bash
set -euo pipefail

# Install this self-contained package under XDG_DATA_HOME.  Optional Omarchy
# integration adds *symlinks* to an existing writable Omarchy bin directory;
# it never edits Omarchy's updater or plugin files.

source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
data_root=${XDG_DATA_HOME:-"$HOME/.local/share"}/omarchy/agent-usage-plus-collectors
omarchy_bin=""
enable_timer=false
with_transcript_cost=false

usage() {
  cat <<'EOF'
Usage: ./collectors/install.sh [--omarchy-bin DIR] [--enable-timer] [--with-transcript-cost]

Installs collectors into $XDG_DATA_HOME/omarchy/agent-usage-plus-collectors.
--omarchy-bin DIR additionally links the two omarchy-agent-usage-* commands
into a writable Omarchy bin directory so Omarchy's usage updater invokes them.
--enable-timer installs a 10-minute user-level systemd timer for the standalone
runner. It is useful when the Omarchy bin directory is not user-writable.
--with-transcript-cost additionally links cost-decorating Claude/Codex wrappers.
It refuses to replace an existing collector; preserve a base scanner first.
EOF
}

while (($#)); do
  case "$1" in
    --omarchy-bin) omarchy_bin=${2:?--omarchy-bin needs a directory}; shift 2 ;;
    --enable-timer) enable_timer=true; shift ;;
    --with-transcript-cost) with_transcript_cost=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if $with_transcript_cost && [[ -z $omarchy_bin ]]; then
  echo "--with-transcript-cost requires --omarchy-bin DIR" >&2
  exit 2
fi

mkdir -p "$data_root"
cp -a "$source_root/agent_usage_collectors" "$data_root/"
mkdir -p "$data_root/bin"
cp -a "$source_root/bin/." "$data_root/bin/"
mkdir -p "$data_root/scripts" "$data_root/logic"
cp -a "$(dirname "$source_root")/scripts/calculate-api-cost" "$data_root/scripts/"
cp -a "$(dirname "$source_root")/logic/cost.js" "$(dirname "$source_root")/logic/api-price-catalogue.js" "$data_root/logic/"
chmod 0755 "$data_root/bin/agent-usage-plus-collectors" "$data_root/bin/omarchy-agent-usage-openrouter" "$data_root/bin/omarchy-agent-usage-deepseek" "$data_root/bin/omarchy-agent-usage-claude-cost" "$data_root/bin/omarchy-agent-usage-codex-cost" "$data_root/scripts/calculate-api-cost"

if [[ -n $omarchy_bin ]]; then
  [[ -d $omarchy_bin && -w $omarchy_bin ]] || { echo "Not a writable Omarchy bin directory: $omarchy_bin" >&2; exit 1; }
  ln -sfn "$data_root/bin/omarchy-agent-usage-openrouter" "$omarchy_bin/omarchy-agent-usage-openrouter"
  ln -sfn "$data_root/bin/omarchy-agent-usage-deepseek" "$omarchy_bin/omarchy-agent-usage-deepseek"
  if $with_transcript_cost; then
    for provider in claude codex; do
      target="$omarchy_bin/omarchy-agent-usage-$provider"
      [[ ! -e $target && ! -L $target ]] || { echo "Refusing to replace existing $target; preserve it as AGENT_USAGE_PLUS_${provider^^}_BASE_COLLECTOR first." >&2; exit 1; }
      ln -s "$data_root/bin/omarchy-agent-usage-$provider-cost" "$target"
    done
  fi
fi

if $enable_timer; then
  unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user
  mkdir -p "$unit_dir"
  cat > "$unit_dir/agent-usage-plus-collectors.service" <<EOF
[Unit]
Description=Refresh Agent Usage Plus API-provider records

[Service]
Type=oneshot
ExecStart=$data_root/bin/agent-usage-plus-collectors update
EOF
  cat > "$unit_dir/agent-usage-plus-collectors.timer" <<'EOF'
[Unit]
Description=Periodically refresh Agent Usage Plus API-provider records

[Timer]
OnBootSec=1m
OnUnitActiveSec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now agent-usage-plus-collectors.timer
fi

printf 'Installed collectors at %s\n' "$data_root"
printf 'Run: %s/bin/agent-usage-plus-collectors update\n' "$data_root"
