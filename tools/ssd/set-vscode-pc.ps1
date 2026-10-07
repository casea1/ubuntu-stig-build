# set-vscode-pc.ps1 -- set up VS Code on ONE Windows PC for Remote-SSH to the
# air-gapped boxes, for EVERY user of that PC, present and future. Run it
# through set-vscode-pc.bat (double-click; it asks for administrator).
#
#   set-vscode-pc.bat           apply
#   set-vscode-pc.bat check     show what is set, change nothing
#
# Two halves, because VS Code offers two mechanisms and neither covers it all:
#
#  1. MACHINE POLICY (HKLM\SOFTWARE\Policies\Microsoft\VSCode). VS Code reads
#     these itself, they apply to every account, and a user cannot override
#     them. Only VS Code's OWN settings can be policies:
#       UpdateMode=none          the PC must stay on the version staged on the boxes
#       ExtensionsAutoUpdate=off
#       TelemetryLevel=off       nothing to send it to
#     The same three can come from a domain GPO instead (VS Code's ADMX).
#
#  2. EACH USER'S settings.json. Remote-SSH is an extension, and extension
#     settings cannot be policies, so they are written into every profile on
#     the PC -- and into the Default profile, which new accounts are copied
#     from:
#       remote.SSH.useExecServer: false     the server layout it-vscode-server stages
#       remote.SSH.localServerDownload: off the PC has no internet either
#       remote.SSH.lockfilesInTmp: true     needed until a box is re-linked
#                                           (it-pull scripts); harmless after
#     The file is EDITED, not replaced: everything else in it -- comments
#     included -- is kept, and the original is copied to settings.json.bak-<time>
#     first. An edit that would not read back as valid is not written.
#
# Written for Windows PowerShell 5.1 -- no newer syntax.
param(
  [string]$Mode = 'apply',
  [string]$UsersRoot = '',       # testing: profile folders under this path, no registry
  [switch]$NoPolicy
)
$ErrorActionPreference = 'Stop'

function Say($m)  { Write-Host "  $m" }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  $m" -ForegroundColor Red }

$Check = ($Mode -eq 'check')
if ($Mode -ne 'apply' -and -not $Check) { Bad "unknown mode '$Mode' -- use: apply | check"; exit 2 }

$Policies = [ordered]@{
  'UpdateMode'           = 'none'
  'ExtensionsAutoUpdate' = 'off'
  'TelemetryLevel'       = 'off'
}
# Values are JSON literals, written as they appear in settings.json.
$UserSettings = [ordered]@{
  'remote.SSH.useExecServer'       = 'false'
  'remote.SSH.localServerDownload' = '"off"'
  'remote.SSH.lockfilesInTmp'      = 'true'
}

# ---------------------------------------------------------------------------
# JSONC: settings.json allows comments and trailing commas, which
# ConvertFrom-Json does not. One scanner finds the top-level keys (with where
# each value starts and ends) and also produces a comment-free copy for the
# read-back check. Strings are tracked so "http://x" is not taken for a comment.
# ---------------------------------------------------------------------------
function Read-Jsonc([string]$t) {
  $r = @{ Ok = $false; Map = @{}; Close = -1; LastSig = -1; Plain = '' }
  $sb = New-Object System.Text.StringBuilder
  $n = $t.Length; $i = 0; $depth = 0; $state = 'none'
  $key = $null; $vs = -1; $lastSig = -1
  while ($i -lt $n) {
    $c = $t[$i]
    if ($c -eq '/' -and $i + 1 -lt $n -and $t[$i + 1] -eq '/') {
      while ($i -lt $n -and $t[$i] -ne "`n") { $i++ }
      continue
    }
    if ($c -eq '/' -and $i + 1 -lt $n -and $t[$i + 1] -eq '*') {
      $e = $t.IndexOf('*/', $i + 2)
      if ($e -lt 0) { return $r }
      $i = $e + 2; [void]$sb.Append(' '); continue
    }
    if ($c -eq '"') {
      $s = $i; $i++
      while ($i -lt $n -and $t[$i] -ne '"') { if ($t[$i] -eq '\') { $i++ }; $i++ }
      if ($i -ge $n) { return $r }
      [void]$sb.Append($t.Substring($s, $i - $s + 1))
      if ($depth -eq 1 -and $state -eq 'key') {
        $key = $t.Substring($s + 1, $i - $s - 1); $state = 'colon'
      } elseif ($depth -eq 1 -and $state -eq 'value') { $vs = $s; $state = 'invalue' }
      $lastSig = $i; $i++; continue
    }
    [void]$sb.Append($c)
    if ([char]::IsWhiteSpace($c)) { $i++; continue }
    if ($depth -eq 1 -and $state -eq 'value') { $vs = $i; $state = 'invalue' }
    switch ($c) {
      '{' { if ($depth -eq 0) { $state = 'key' }; $depth++ }
      '[' { $depth++ }
      ':' { if ($depth -eq 1 -and $state -eq 'colon') { $state = 'value' } }
      ',' {
        if ($depth -eq 1) {
          if ($state -eq 'invalue') {
            if (-not $r.Map.ContainsKey($key)) { $r.Map[$key] = @() }
            $r.Map[$key] += ,@($vs, $lastSig)
          }
          $state = 'key'
        }
      }
      ']' { $depth-- }
      '}' {
        $depth--
        if ($depth -eq 0) {
          if ($state -eq 'invalue') {
            if (-not $r.Map.ContainsKey($key)) { $r.Map[$key] = @() }
            $r.Map[$key] += ,@($vs, $lastSig)
          }
          $r.Close = $i; $r.LastSig = $lastSig; $r.Ok = $true
          [void]$sb.Append($t.Substring($i + 1))
          $r.Plain = $sb.ToString()
          return $r
        }
      }
    }
    $lastSig = $i; $i++
  }
  return $r
}

function Test-Result([string]$t, $want) {   # $true when every wanted key reads back as wanted
  $p = Read-Jsonc $t
  if (-not $p.Ok) { return $false }
  $plain = [regex]::Replace($p.Plain, ',(\s*[}\]])', '$1')
  try { $o = $plain | ConvertFrom-Json } catch { return $false }
  foreach ($k in $want.Keys) {
    $got = $o.PSObject.Properties[$k]
    if ($null -eq $got) { return $false }
    if ((ConvertTo-Json $got.Value -Compress) -ne $want[$k]) { return $false }
  }
  return $true
}

function Set-Jsonc([string]$t, $want) {   # -> new text, or $null if it cannot be done safely
  if ($t.Trim().Length -eq 0) {
    $lines = @(); foreach ($k in $want.Keys) { $lines += "    `"$k`": $($want[$k])" }
    return "{`r`n" + ($lines -join ",`r`n") + "`r`n}`r`n"
  }
  $p = Read-Jsonc $t
  if (-not $p.Ok) { return $null }
  $ind = '    '
  $m = [regex]::Match($t, '(?m)^([ \t]+)"')
  if ($m.Success) { $ind = $m.Groups[1].Value }   # the file's own indentation
  $edits = @()   # start, end (inclusive), new text -- applied from the end backwards
  $missing = @()
  foreach ($k in $want.Keys) {
    if ($p.Map.ContainsKey($k)) {
      foreach ($span in $p.Map[$k]) { $edits += [pscustomobject]@{ S = [int]$span[0]; E = [int]$span[1]; T = $want[$k] } }
    } else { $missing += $k }
  }
  if ($missing.Count -gt 0) {
    $lines = @(); foreach ($k in $missing) { $lines += "$ind`"$k`": $($want[$k])" }
    $body = ($lines -join ",`r`n")
    $prev = $t[$p.LastSig]
    if ($prev -eq '{')     { $ins = "`r`n$body`r`n" }
    elseif ($prev -eq ',') { $ins = "`r`n$body" }
    else                   { $ins = ",`r`n$body" }
    $edits += [pscustomobject]@{ S = $p.LastSig + 1; E = $p.LastSig; T = $ins }   # an insertion
  }
  $out = $t
  foreach ($e in @($edits | Sort-Object S -Descending)) {
    $len = [Math]::Max(0, $e.E - $e.S + 1)
    $out = $out.Substring(0, $e.S) + $e.T + $out.Substring($e.S + $len)
  }
  return $out
}

# ---------------------------------------------------------------------------
# which profiles
# ---------------------------------------------------------------------------
function Get-Profiles {
  if ($UsersRoot) {
    return @(Get-ChildItem -LiteralPath $UsersRoot -Directory | ForEach-Object { $_.FullName })
  }
  $list = @()
  $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
  foreach ($k in Get-ChildItem $pl) {
    if ($k.PSChildName -notlike 'S-1-5-21-*') { continue }   # real accounts, not SYSTEM/services
    $path = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty $k.PSPath).ProfileImagePath)
    if (Test-Path -LiteralPath $path) { $list += $path }
  }
  $def = (Get-ItemProperty $pl).Default
  if ($def) { $list += [Environment]::ExpandEnvironmentVariables($def) }
  return $list
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  VS Code on this PC, for Remote-SSH to the boxes$(if ($Check) { '  (check only)' })" -ForegroundColor Cyan
$fail = 0

if (-not $NoPolicy -and -not $UsersRoot) {
  Write-Host ""; Say "Machine policy  HKLM\SOFTWARE\Policies\Microsoft\VSCode"
  $key = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'
  foreach ($name in $Policies.Keys) {
    $cur = $null
    try { $cur = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop).$name } catch {}
    if ($cur -eq $Policies[$name]) { Ok ("{0,-22} {1}" -f $name, $cur); continue }
    if ($Check) { Warn ("{0,-22} {1}  (want {2})" -f $name, $(if ($null -eq $cur) { 'not set' } else { $cur }), $Policies[$name]); continue }
    try {
      if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
      New-ItemProperty -LiteralPath $key -Name $name -Value $Policies[$name] -PropertyType String -Force | Out-Null
      Ok ("{0,-22} {1}  (set)" -f $name, $Policies[$name])
    } catch { Bad ("{0,-22} FAILED: {1}" -f $name, $_.Exception.Message); $fail++ }
  }
}

Write-Host ""; Say "Each profile's settings.json (Remote-SSH)"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($prof in Get-Profiles) {
  $dir  = Join-Path $prof 'AppData\Roaming\Code\User'
  $file = Join-Path $dir 'settings.json'
  $who  = Split-Path $prof -Leaf
  try {
    $text = ''
    if (Test-Path -LiteralPath $file) { $text = [IO.File]::ReadAllText($file) }
    if ($text.Trim().Length -gt 0 -and (Test-Result $text $UserSettings)) { Ok ("{0,-24} already set" -f $who); continue }
    if ($Check) { Warn ("{0,-24} NOT set" -f $who); continue }
    $new = Set-Jsonc $text $UserSettings
    if ($null -eq $new -or -not (Test-Result $new $UserSettings)) {
      Bad ("{0,-24} left alone: its settings.json does not parse -- add the lines by hand" -f $who); $fail++; continue
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination "$file.bak-$stamp" }
    # UTF-8 without a BOM, as VS Code writes it.
    [IO.File]::WriteAllText($file, $new, (New-Object System.Text.UTF8Encoding $false))
    Ok ("{0,-24} {1}" -f $who, $(if ($text.Trim().Length -eq 0) { 'created' } else { 'updated (backup: settings.json.bak-' + $stamp + ')' }))
  } catch { Bad ("{0,-24} FAILED: {1}" -f $who, $_.Exception.Message); $fail++ }
}

Write-Host ""
if ($fail -gt 0) { Bad "$fail problem(s) above."; exit 1 }
if ($Check) { Say "Nothing changed (check)." } else {
  Ok "Done. Open VS Code windows pick up the policy at their next start."
  Say "Every PC must still run EXACTLY the VS Code version staged on the boxes."
}
Write-Host ""
exit 0
