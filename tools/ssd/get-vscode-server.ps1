# get-vscode-server.ps1 -- download everything an air-gapped box and its PCs
# need for VS Code Remote-SSH, for ONE exact VS Code version.
#
# Run it through get-vscode-server.bat (double-click). On a PC with internet.
#
#   get-vscode-server.bat                 the version of VS Code on THIS PC
#   get-vscode-server.bat 1.139.1         a version by number
#   get-vscode-server.bat <40-hex commit> a version by commit (Help > About)
#   get-vscode-server.bat latest          the newest release
#
# Leaves a folder vscode-<version>\ beside itself:
#   vscode-server-linux-x64.tar.gz      \  for the box:
#   vscode_cli_alpine_x64_cli.tar.gz    /    sudo it-vscode-server stage <folder>
#   VSCodeSetup-x64-<version>.exe          for the PCs (all-users installer)
#   code_<version>-<build>_amd64.deb       the desktop VS Code for the Linux
#                                          boxes, to put them all on one version
#   extensions\*.vsix                      Remote-SSH + the two it pulls in
#   README.txt                             version, commit, hashes, next steps
#
# Every download is checked against the SHA-256 Microsoft's update service
# publishes for it. Written for Windows PowerShell 5.1 -- no newer syntax.
param([string]$Want = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'    # 5.1's progress bar makes downloads crawl
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Set-Location -LiteralPath $PSScriptRoot

function Say($m)  { Write-Host "  $m" }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host ""; Write-Host "  [X] $m" -ForegroundColor Red; Write-Host ""; exit 1 }

$api = 'https://update.code.visualstudio.com/api'

# Windows PowerShell 5.1 turns ANY stderr line from a native program into a
# terminating error while ErrorActionPreference is Stop -- so a curl.exe that
# merely complains would skip the fallback. Native calls run with Continue.
function Invoke-Native([scriptblock]$sb) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { return @(& $sb) } finally { $ErrorActionPreference = $old }
}

# ---- which version -------------------------------------------------------
# Default: whatever VS Code this PC runs. `code --version` prints the version
# on line 1 and the commit on line 2.
if ($Want -eq '') {
  $code = $null
  $c = Get-Command code.cmd -ErrorAction SilentlyContinue
  if ($c) { $code = $c.Source }
  foreach ($p in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
                   "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd")) {
    if (-not $code -and (Test-Path -LiteralPath $p)) { $code = $p }
  }
  if ($code) {
    $lines = Invoke-Native { & $code --version 2>$null }
    if ($lines.Count -ge 2 -and $lines[1] -cmatch '^[0-9a-f]{40}$') {
      $Want = $lines[1]
      Say "VS Code on this PC: $($lines[0])  (commit $Want)"
    }
  }
  if ($Want -eq '') {
    Warn "No VS Code found on this PC."
    $Want = (Read-Host "  Type a version (e.g. 1.139.1), a commit, or press Enter for the latest").Trim()
    if ($Want -eq '') { $Want = 'latest' }
  }
}

function Get-Info($platform) {
  if ($Want -eq 'latest') {
    # /api/versions has no 'latest'; resolve it to a commit once, then ask by commit.
    $l = Invoke-RestMethod -UseBasicParsing "$api/update/win32-x64/stable/latest"
    $script:Want = $l.version
  }
  $key = $Want
  if ($Want -cmatch '^[0-9a-f]{40}$') { $key = "commit:$Want" }
  try { return Invoke-RestMethod -UseBasicParsing "$api/versions/$key/$platform/stable" }
  catch { Die "Microsoft's update service does not know '$Want' for $platform. Check the version or commit (VS Code: Help > About)." }
}

if ($Want -ne 'latest' -and $Want -notmatch '^\d+\.\d+\.\d+$' -and $Want -cnotmatch '^[0-9a-f]{40}$') {
  Die "'$Want' is not a version (1.139.1), a 40-character lowercase commit, or 'latest'."
}

$files = @(
  @{ plat = 'server-linux-x64'; name = 'vscode-server-linux-x64.tar.gz' },
  @{ plat = 'cli-alpine-x64';   name = 'vscode_cli_alpine_x64_cli.tar.gz' },
  @{ plat = 'win32-x64';        name = '' },           # named from its URL
  @{ plat = 'linux-deb-x64';    name = '' }
)
foreach ($f in $files) { $f.info = Get-Info $f.plat }
$ver    = $files[0].info.productVersion
$commit = $files[0].info.version
foreach ($f in $files) {
  if ($f.info.version -ne $commit) { Die "Microsoft returned different commits for the server and $($f.plat) -- try again." }
  if ($f.name -eq '') { $f.name = ($f.info.url -split '/')[-1] }
}

$out = Join-Path $PSScriptRoot "vscode-$ver"
Write-Host ""
Write-Host "  VS Code $ver   commit $commit" -ForegroundColor Cyan
Write-Host "  into $out"
Write-Host ""
New-Item -ItemType Directory -Force -Path $out, (Join-Path $out 'extensions') | Out-Null

# ---- download ------------------------------------------------------------
# curl.exe first (Windows 10 1803+; fast), Invoke-WebRequest if it is missing
# or fails -- IWR follows the system proxy, which curl.exe does not.
function Fetch($url, $dest) {
  $part = "$dest.part"
  Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    Invoke-Native { & $curl.Source -fsSL --retry 2 -o $part $url 2>$null } | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $part)) { return $part }
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
  }
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $part
  return $part
}

$total = $files.Count + 1
$n = 0
foreach ($f in $files) {
  $n++
  $dest = Join-Path $out $f.name
  $want = "$($f.info.sha256hash)".ToLower()
  if ((Test-Path -LiteralPath $dest) -and $want -and
      ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower() -eq $want)) {
    Ok "[$n/$total] $($f.name) -- already here, hash matches"
    continue
  }
  Say "[$n/$total] $($f.name) ..."
  try { $part = Fetch $f.info.url $dest } catch { Die "download failed: $($f.info.url)`n      $($_.Exception.Message)" }
  $got = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLower()
  if ($want -and $got -ne $want) {
    Remove-Item -LiteralPath $part -Force
    Die "$($f.name): SHA-256 does not match what Microsoft publishes. Deleted. Try again."
  }
  Move-Item -LiteralPath $part -Destination $dest -Force
  Ok "      done, SHA-256 verified"
}

# ---- Remote-SSH and the pack it installs ---------------------------------
# The Marketplace serves a .vsix GZIP-ENCODED. curl.exe on Windows is built
# without zlib and 5.1's IWR does not decode it, so either one leaves a gzip
# file named .vsix that VS Code rejects. Unwrapped here, then checked to be a
# zip. Remote-SSH is an extension PACK: offline, its two members must be
# installed first or the install stops.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$exts = @('ms-vscode-remote.remote-ssh-edit', 'ms-vscode.remote-explorer', 'ms-vscode-remote.remote-ssh')
Say "[$total/$total] Remote-SSH extensions ..."
$extNames = @()
foreach ($e in $exts) {
  $pub, $nm = $e -split '\.', 2
  $url = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/$pub/vsextensions/$nm/latest/vspackage"
  try { $part = Fetch $url (Join-Path $out "extensions\$e.vsix") }
  catch { Warn "      $e -- download failed, skipped ($($_.Exception.Message))"; continue }
  $b = [IO.File]::ReadAllBytes($part)
  if ($b.Length -gt 2 -and $b[0] -eq 0x1f -and $b[1] -eq 0x8b) {
    $gz = New-Object IO.Compression.GZipStream((New-Object IO.MemoryStream(,$b)), [IO.Compression.CompressionMode]::Decompress)
    $ms = New-Object IO.MemoryStream; $gz.CopyTo($ms); $gz.Dispose(); $b = $ms.ToArray()
  }
  Remove-Item -LiteralPath $part -Force
  if (-not ($b.Length -gt 2 -and $b[0] -eq 0x50 -and $b[1] -eq 0x4b)) { Warn "      $e -- not a valid .vsix, skipped"; continue }
  # Version and required engine from the manifest: package.json is minified,
  # and 5.1's ConvertFrom-Json rejects keys that differ only in case.
  $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(,$b)))
  $entry = $zip.GetEntry('extension.vsixmanifest')
  $txt = ''
  if ($entry) { $txt = (New-Object IO.StreamReader($entry.Open())).ReadToEnd() }
  $zip.Dispose()
  $ev = ''; $need = ''
  if ($txt -match '<Identity[^>]*\sVersion="([^"]+)"') { $ev = $Matches[1] }
  if ($txt -match 'Id="Microsoft\.VisualStudio\.Code\.Engine"\s+Value="[^"\d]*([\d\.]+)"') { $need = $Matches[1] }
  $file = "$e.vsix"
  if ($ev) { $file = "$e-$ev.vsix" }
  # An older download of THIS extension only: "remote-ssh-*" would also match
  # remote-ssh-edit, which is how the first version deleted it.
  $mine = '^' + [regex]::Escape($e) + '-\d[\w\.]*\.vsix$'
  Get-ChildItem -LiteralPath (Join-Path $out 'extensions') -Filter '*.vsix' |
    Where-Object { $_.Name -match $mine } | Remove-Item -Force
  [IO.File]::WriteAllBytes((Join-Path $out "extensions\$file"), $b)
  $extNames += $file
  # "latest" can need a NEWER VS Code than the one being carried in.
  if ($need -and ([version]$need -gt [version]$ver)) {
    Warn "      $file needs VS Code $need or later -- this bundle is $ver. It will refuse to install."
  } else {
    Ok "      $file"
  }
}

# ---- README --------------------------------------------------------------
$readme = @"
VS Code $ver   commit $commit
Downloaded $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME

SHA-256
"@
foreach ($f in $files) { $readme += "`r`n  $((Get-FileHash -LiteralPath (Join-Path $out $f.name) -Algorithm SHA256).Hash.ToLower())  $($f.name)" }
$readme += @"


ON EACH LINUX BOX (copy this whole folder to the box first, e.g. with WinSCP
into your home directory):

  sudo it-vscode-server stage ~/vscode-$ver

It checks the files, installs one shared copy in /opt/vscode-server, and links
every member of 'sentry'. Check with: sudo it-vscode-server

To put the box's OWN desktop VS Code on this version too (optional -- only
matters if people Remote-SSH FROM this box, or you want one version fleet-wide):

  echo "code code/add-microsoft-repo boolean false" | sudo debconf-set-selections
  sudo apt install ~/vscode-$ver/$($files[3].name)
  sudo apt-mark hold code        # so a later apt upgrade cannot drift it again

The first line answers the package's "add Microsoft's apt repository?" question
with NO. Left unanswered it adds packages.microsoft.com, and every apt update on
an air-gapped box then waits on it.
Extensions are not touched: they live in /opt/vscode-extensions and in each
user's home, not in the package.

ON EACH ENGINEER'S PC:

  1. Install $($files[2].name)  (every PC must run exactly $ver)
  2. Extensions > ... > Install from VSIX, in this order:
       $($extNames -join "`r`n       ")
  3. Run set-vscode-pc.bat (from the SSD's tools\ssd folder) once per PC, as
     administrator: it locks updates off for every user of the PC and writes
     the Remote-SSH settings into every profile, new accounts included.
  4. Remote-SSH: Connect to Host -> user@box
"@
Set-Content -LiteralPath (Join-Path $out 'README.txt') -Value $readme -Encoding ASCII

Write-Host ""
Write-Host "  ==================================================================" -ForegroundColor Cyan
Write-Host "   Done.  $out"
Write-Host "   Next:  copy the folder to each box, then"
Write-Host "            sudo it-vscode-server stage ~/vscode-$ver"
Write-Host "          README.txt has the PC steps."
Write-Host "  ==================================================================" -ForegroundColor Cyan
Write-Host ""
