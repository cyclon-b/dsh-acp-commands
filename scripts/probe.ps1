# probe.ps1 — drive the acp profile over stdio and print what a client would see.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\probe.ps1 `
#     -Prompts "/goal demo objective;/goal;/compact;/plan;reply with pong"
#
# Prompts are separated by ';'. Prints the session/new result, every notification
# the server emits (including available_commands_update), each prompt response
# and any stderr the server wrote.
param(
  [string] $Prompts = '',
  [string] $Cwd = (Get-Location).Path,
  [string] $Dsh = 'dsh',
  [int] $TimeoutMs = 120000
)
$ErrorActionPreference = 'Stop'
$promptList = @($Prompts -split '\s*;\s*' | Where-Object { $_ -ne '' })

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'cmd.exe'
$psi.Arguments = "/c $Dsh --profile acp"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$p = [System.Diagnostics.Process]::Start($psi)

$global:outQ = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$global:errQ = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$null = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action { $global:outQ.Enqueue($EventArgs.Data) }
$null = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived  -Action { $global:errQ.Enqueue($EventArgs.Data) }
$p.BeginOutputReadLine(); $p.BeginErrorReadLine()

function Wait-Id([int]$id, [int]$timeout) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $timeout) {
    $line = $null
    if ($global:outQ.TryDequeue([ref]$line) -and $null -ne $line) {
      $o = $null
      try { $o = $line | ConvertFrom-Json } catch { continue }
      if ($o.PSObject.Properties.Name -contains 'id' -and $o.id -eq $id) { return $line }
      if ($o.method) { $script:notifications += $line }
      continue
    }
    if ($p.HasExited -and $global:outQ.IsEmpty) { return '{"error":"process exited"}' }
    Start-Sleep -Milliseconds 40
  }
  return '{"error":"timeout"}'
}

$script:notifications = @()
$send = { param($s) $p.StandardInput.WriteLine($s) }

& $send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}}'
$init = Wait-Id 1 60000
if ($init -like '*error*') { Write-Output "INIT => $init" }

& $send ('{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"' + ($Cwd -replace '\\','\\') + '","mcpServers":[]}}')
$session = Wait-Id 2 60000
$sid = $null
try { $sid = ($session | ConvertFrom-Json).result.sessionId } catch {}
if (-not $sid) { Write-Output "SESSION/NEW => $session" }

$id = 3
$results = @()
foreach ($prompt in $promptList) {
  $payload = @{ jsonrpc='2.0'; id=$id; method='session/prompt'; params=@{ sessionId=$sid; prompt=@(@{ type='text'; text=$prompt }) } } | ConvertTo-Json -Depth 8 -Compress
  & $send $payload
  $results += [pscustomobject]@{ prompt=$prompt; response=(Wait-Id $id $TimeoutMs) }
  $id++
}

& $send ('{"jsonrpc":"2.0","id":' + $id + ',"method":"session/close","params":{"sessionId":"' + $sid + '"}}')
$null = Wait-Id $id 30000

$p.StandardInput.Close()
$p.WaitForExit(20000) | Out-Null
Start-Sleep -Milliseconds 200

Write-Output '=== session/new result ==='
if ($session.Length -gt 400) { $session.Substring(0,400) } else { $session }

Write-Output '=== notifications ==='
foreach ($n in $script:notifications) {
  $o = $null; try { $o = $n | ConvertFrom-Json } catch { Write-Output $n; continue }
  $u = $o.params.update
  if ($null -eq $u) { Write-Output ("[?] " + $n); continue }
  switch ($u.sessionUpdate) {
    'available_commands_update' {
      Write-Output ("available_commands_update: " + (($u.availableCommands | ForEach-Object { '/' + $_.name + $(if ($_.input) { ' ' + $_.input.hint } else { '' }) }) -join ' | '))
    }
    'agent_message_chunk' { Write-Output ("agent_message_chunk: " + $u.content.text) }
    'agent_thought_chunk' { }
    default { Write-Output ("[" + $u.sessionUpdate + "]") }
  }
}

Write-Output '=== prompts ==='
foreach ($r in $results) {
  Write-Output ("/ " + $r.prompt)
  if ($r.response.Length -gt 300) { Write-Output ("  <= " + $r.response.Substring(0,300)) } else { Write-Output ("  <= " + $r.response) }
}

$errText = ($global:errQ.ToArray() -join "`n")
if ($errText) { Write-Output ("=== stderr ===`n" + $errText.Substring(0, [Math]::Min(3000, $errText.Length))) } else { Write-Output '=== stderr: empty ===' }
