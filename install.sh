#!/usr/bin/env sh
# Installs the ACP slash-command fork into the active dsh installation and wires
# it into the `acp` profile that Zed launches.
#
#   ./install.sh            # install / refresh
#   ./install.sh --revert   # restore the stock ACP bridge
#
# Best effort: verified on Windows via install.ps1; POSIX path is untested.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
upstream_name='dsh-acp-commands'
supported_dsh='0.2.1-rc.2'

node_modules=$(npm root -g | head -n 1)
dsh_root="$node_modules/@deepseek-ai/dsh"
upstream="$dsh_root/node_modules/@deepseek-ai/dsh-acp/lib/index.js"
fork_root="$dsh_root/node_modules/$upstream_name"
profile="${DSH_HOME:-$HOME/.dsh}/profiles/acp"
link="$profile/node_modules/$upstream_name"
patch="$profile/cordis.patch.yml"

[ -f "$upstream" ] || { echo "stock ACP bridge not found: $upstream" >&2; exit 1; }
[ -d "$profile" ] || { echo "acp profile not initialized; run: dsh --profile acp --help" >&2; exit 1; }

patch_yaml='# Local ACP command surface: exposes the harness slash commands (/goal,
# /compact, /plan, /permission, /feedback) to ACP clients such as Zed.
#
# The stock `acp` row is disabled and replaced by `dsh-acp-commands`, an additive
# fork of @deepseek-ai/dsh-acp that advertises `available_commands_update` and
# dispatches slash prompts through the harness command registry.

- id: acp
  disabled: true

- insert:
    - id: acp-commands
      name: '"'"'dsh-acp-commands'"'"'
      inject: [acpAppStartup]
      config:
        provider: deepseek-official
        model: deepseek-v4-flash
'

if [ "${1:-}" = '--revert' ]; then
  [ -L "$link" ] && rm -f "$link"
  [ -d "$fork_root" ] && rm -rf "$fork_root"
  if [ -f "$patch" ] && grep -q 'acp-commands' "$patch"; then
    printf '# Your patch layer for this dsh profile.\n[]\n' > "$patch"
  fi
  echo 'Reverted: stock @deepseek-ai/dsh-acp serves the acp profile again.'
  exit 0
fi

dsh_version=$(dsh --version 2>/dev/null | head -n 1 || true)
if [ "$dsh_version" != "$supported_dsh" ]; then
  echo "warning: fork was built against dsh $supported_dsh; installed dsh is $dsh_version" >&2
  echo "warning: port the four hooks in docs/patches.md before trusting the result" >&2
fi

# 1. Materialize the fork beside the stock bridge so it resolves the same package
#    instances (cordis, dsh-agent, ACP SDK) as the rest of the installation.
mkdir -p "$fork_root/lib"
cp "$here/lib/index.js" "$fork_root/lib/index.js"
cp "$here/package.json" "$fork_root/package.json"

# 2. Make it resolvable from the profile.
mkdir -p "$profile/node_modules"
if [ -L "$link" ]; then rm -f "$link"; fi
if [ -e "$link" ]; then echo "refusing to replace non-symlink: $link" >&2; exit 1; fi
ln -s "$fork_root" "$link"

# 3. Point the profile at the fork (only when the patch layer is still untouched).
if [ -f "$patch" ] && grep -q 'acp-commands' "$patch"; then
  echo 'patch already installed'
elif [ -f "$patch" ] && grep -qE '^[[:space:]]*-[[:space:]]' "$patch"; then
  echo "warning: $patch has other entries; add the acp/insert rows from install.sh manually" >&2
else
  printf '%s' "$patch_yaml" > "$patch"
  echo "patched: $patch"
fi

echo "fork:     $fork_root"
echo "link:     $link"
echo 'verify:   run the probe from scripts/probe.ps1 on Windows, or drive the server with any ACP client'
