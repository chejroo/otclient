#requires -Version 5.1
<#
Builds the zip a friend gets, from this working copy.

Three things it does that a plain zip of the folder does not.

It leaves out data\things and data\sounds, 235 MB of CipSoft assets that must
never be redistributed. The client downloads them itself on first launch for
client versions 1281 and up, see docs\client-assets-auto-install.md.

It leaves out the repo: .git, src, build, cmake and the rest. A player needs the
executable, init.lua, modules, mods and the non-asset half of data.

And it writes a Servers_init block with exactly one entry. That is the part
worth knowing: with one entry the enter-game screen calls setUniqueServer and
the login field is locked, so nobody can mistype the URL or accidentally point
at MyAAC, whose login.php is removed from the quickstart image and answers
nothing.

Run it after a rebuild, not before: it copies whatever OTClient.exe is sitting
in the repo root right now.
#>
param(
    [string]$PublicIp = "",
    # 8089, not 8088, and this is the trap in the whole exercise. Both ports
    # answer /login and both return a valid character list, so a wrong one looks
    # like it works right up until the client tries to connect. 8088 is the main
    # login-server, which deliberately advertises 127.0.0.1 so this machine does
    # not depend on the router's NAT loopback. 8089 is login-server-friend from
    # docker-compose.override.yml, which advertises CANARY_PUBLIC_IP. Verified
    # by asking both: 8088 answers 127.0.0.1:7172, 8089 answers the public IP.
    [int]$LoginPort = 8089,
    [int]$Protocol = 1525,
    [string]$OutDir = "$env:TEMP\exp-arena-dist"
)

$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot

if (-not $PublicIp) {
    # Same source of truth the login-server-friend service uses, so the zip and
    # the server cannot disagree about where players connect.
    $envFile = Join-Path $repo "..\canary\docker\.env"
    if (Test-Path $envFile) {
        $line = Select-String -Path $envFile -Pattern '^CANARY_PUBLIC_IP=(.+)$' | Select-Object -First 1
        if ($line) { $PublicIp = $line.Matches[0].Groups[1].Value.Trim() }
    }
}
if (-not $PublicIp) { throw "No public IP. Pass -PublicIp or set CANARY_PUBLIC_IP in canary\docker\.env" }

$exe = Join-Path $repo "OTClient.exe"
if (-not (Test-Path $exe)) { throw "OTClient.exe is not in $repo. Build it first." }

$stage = Join-Path $OutDir "exp-arena-client"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item $exe (Join-Path $stage "OTClient.exe")
foreach ($f in @("init.lua", "meta.lua", "otclientrc.lua")) {
    $p = Join-Path $repo $f
    if (Test-Path $p) { Copy-Item $p $stage }
}
Copy-Item -Recurse (Join-Path $repo "modules") (Join-Path $stage "modules")
Copy-Item -Recurse (Join-Path $repo "mods")    (Join-Path $stage "mods")
Copy-Item -Recurse (Join-Path $repo "data")    (Join-Path $stage "data")
Remove-Item -Recurse -Force (Join-Path $stage "data\things"), (Join-Path $stage "data\sounds") -ErrorAction SilentlyContinue

# One entry, so the enter-game screen locks the field instead of offering a
# dropdown. The game port is not set here on purpose: with httpLogin the login
# webservice hands back the address to connect to.
$loginUrl = "http://${PublicIp}:${LoginPort}/login"
$servers = @"
Servers_init = {
    ["$loginUrl"] = {
        port = $LoginPort,
        protocol = $Protocol,
        httpLogin = true,
        useAuthenticator = false
    }
}
"@

$initPath = Join-Path $stage "init.lua"
$init = Get-Content $initPath -Raw
# Replace the whole guarded block, which is upstream's two examples, rather than
# editing inside it. Anchored on the assignment and the "end" that closes the
# if, so a future upstream edit inside the block cannot leave a half patch.
$pattern = '(?s)Servers_init = \{\}\s*\r?\nif ENABLE_SERVERS then.*?\r?\n[ \t]*\}\r?\nend'
if ($init -notmatch $pattern) { throw "init.lua does not look like upstream's. Check the Servers_init block by hand." }
$init = [regex]::Replace($init, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $servers }, 1)
Set-Content -Path $initPath -Value $init -Encoding UTF8 -NoNewline

$zip = Join-Path $OutDir "exp-arena-client.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal

$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Output "login   $loginUrl"
Write-Output "zip     $zip  ($mb MB)"
Write-Output "assets  not included, the client installs 1525 on first launch"
