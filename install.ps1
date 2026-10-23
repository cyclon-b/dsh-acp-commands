# Installs the local ACP slash-command fork into the active dsh installation and
# wires it into the `acp` profile that Zed launches.
#
#   pwsh -File install.ps1            # install / refresh
#   pwsh -File install.ps1 -Force     # install even if the dsh version changed
#   pwsh -File install.ps1 -Revert    # restore the stock ACP bridge
param(
  [switch] $Force,
  [switch] $Revert
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgName = 'dsh-acp-commands'
$supportedDsh = '0.2.1-rc.2'

function Get-GlobalNodeModules {
  $root = (& npm root -g 2>$null | Select-Object -First 1)
  if (-not $root) { throw 'npm root -g returned nothing; is Node on PATH?' }
  return $root.Trim()
}

$nodeModules = Get-GlobalNodeModules
$dshRoot = Join-Path $nodeModules '@deepseek-ai\dsh'
$upstream = Join-Path $dshRoot 'node_modules\@deepseek-ai\dsh-acp\lib\index.js'
$forkRoot = Join-Path $dshRoot "node_modules\$pkgName"
$profile = Join-Path $env:USERPROFILE '.dsh\profiles\acp'
$junction = Join-Path $profile "node_modules\$pkgName"
$patchFile = Join-Path $profile 'cordis.patch.yml'

if (-not (Test-Path $upstream)) { throw "stock ACP bridge not found: $upstream" }
if (-not (Test-Path $profile)) { throw "acp profile not initialized yet; run: dsh --profile acp --help" }

$dshVersion = ((& dsh --version) -join '').Trim()

function Remove-Link([string] $path) {
  if (-not (Test-Path $path)) { return }
  $item = Get-Item $path -Force
  if ($item.LinkType) { $item.Delete() } else { Remove-Item $path -Recurse -Force }
}

$patchYaml = @'
# Local ACP command surface: exposes the harness slash commands (/goal,
# /compact, /plan, /permission, /feedback) to ACP clients such as Zed.
#
# The stock `acp` row is disabled and replaced by `dsh-acp-commands`, an additive
# fork of @deepseek-ai/dsh-acp that advertises `available_commands_update` and
# dispatches slash prompts through the harness command registry. The fork is
# resolved from the global dsh installation through a junction in this profile's
# node_modules. Command producers come from the base bundle at their defaults.

- id: acp
  disabled: true

- insert:
    - id: acp-commands
      name: 'dsh-acp-commands'
      inject: [acpAppStartup]
      config:
        provider: deepseek-official
        model: deepseek-v4-flash
'@

if ($Revert) {
  Remove-Link $junction
  Remove-Link $forkRoot
  if ((Test-Path $patchFile) -and (Select-String -Path $patchFile -Pattern 'acp-commands' -Quiet)) {
    [IO.File]::WriteAllText($patchFile, "# Your patch layer for this dsh profile.`n[]`n", (New-Object Text.UTF8Encoding($false)))
  }
  Write-Output 'Reverted: stock @deepseek-ai/dsh-acp serves the acp profile again.'
  exit 0
}

if ($dshVersion -ne $supportedDsh -and -not $Force) {
  Write-Warning "Fork was built against dsh $supportedDsh; installed dsh is $dshVersion."
  Write-Warning 'The fork is a copy of the stock bridge. Re-derive it from the new upstream, then re-run with -Force:'
  Write-Warning "  copy $upstream over $here\lib\index.js and re-apply the four hooks (see README)."
}
if ((Test-Path (Join-Path $forkRoot 'lib\index.js')) -and (Get-Item (Join-Path $forkRoot 'lib\index.js')).LastWriteTime -gt (Get-Item (Join-Path $here 'lib\index.js')).LastWriteTime -and -not $Force) {
  Write-Warning "Installed fork is newer than the workspace copy. Re-run with -Force to overwrite."
}

# 1. Materialize the fork beside the stock bridge so it resolves the same package
#    instances (cordis, dsh-agent, ACP SDK) as the rest of the installation.
New-Item -ItemType Directory -Force -Path (Join-Path $forkRoot 'lib') | Out-Null
Copy-Item (Join-Path $here 'lib\index.js') (Join-Path $forkRoot 'lib\index.js') -Force
Copy-Item (Join-Path $here 'package.json') (Join-Path $forkRoot 'package.json') -Force

# 2. Make it resolvable from the profile.
New-Item -ItemType Directory -Force -Path (Join-Path $profile 'node_modules') | Out-Null
$existing = Get-Item $junction -Force -ErrorAction SilentlyContinue
if ($existing -and $existing.Target -and ($existing.Target -ne $forkRoot)) { Remove-Link $junction }
if (-not (Test-Path $junction)) { New-Item -ItemType Junction -Path $junction -Target $forkRoot | Out-Null }

# 3. Point the profile at the fork (only when the patch layer is still untouched).
$current = if (Test-Path $patchFile) { Get-Content $patchFile -Raw } else { '' }
if ($current -notmatch 'acp-commands' -and $current -notmatch '^\s*-\s' ) {
  [IO.File]::WriteAllText($patchFile, $patchYaml, (New-Object Text.UTF8Encoding($false)))
  Write-Output "patched: $patchFile"
} elseif ($current -match 'acp-commands') {
  Write-Output 'patch already installed'
} else {
  Write-Warning "  $patchFile has other entries; not overwritten."
  Write-Warning 'Add the acp/insert rows from install.ps1 manually (see README).'
}

Write-Output "fork:     $forkRoot"
Write-Output "junction: $junction"
Write-Output 'verify:   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\probe.ps1 -Prompts "/goal demo;/goal;/compact;/plan;reply with pong"'
