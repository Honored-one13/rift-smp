<#
  Update Rift SMP for everyone.

  1. Gets the latest pack from GitHub (so the PC and the laptop never fight).
  2. Rebuilds the Playful Massacre mod (if its folder sits next to this one) and copies the jar into files/.
  3. Points each self-hosted mod (files/*.jar) at its newest build, e.g. a new ratsmischief jar you dropped in.
  4. Refreshes every hash packwiz checks, exactly as GitHub serves the files.
  5. Bumps the pack version, commits, and pushes. Everyone gets it the next time they press Launch.

  Double-click "Update Pack.bat", or run:  .\update-pack.ps1 [-NoPush] [-NoBuild] [-Version 2.1.3-neoforge.60]
#>
param(
    [switch]$NoPush,   # do everything except commit + push (to check first)
    [switch]$NoBuild,  # don't rebuild the mod projects, just use the jars already there
    [string]$Version   # set the pack version yourself instead of +1
)

$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
$RawBase = 'https://raw.githubusercontent.com/Honored-one13/rift-smp/main/'
$Utf8 = New-Object System.Text.UTF8Encoding $false
# Mod projects that live next to this folder and get built + shipped by this script.
$ModProjects = @()
# Folders whose files go into index.toml (besides mods/*.pw.toml).
$IndexedDirs = @('config', 'resourcepacks', 'shaderpacks', 'defaultconfigs', 'kubejs')

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Magenta }

function Find-Git {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $desktop = Get-ChildItem "$env:LOCALAPPDATA\GitHubDesktop\app-*\resources\app\git\cmd\git.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($desktop) { return $desktop.FullName }
    throw 'Git not found. Install GitHub Desktop or Git for Windows.'
}
$Git = Find-Git

function Invoke-Git {
    & $Git -C $Repo @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed" }
}

function Find-Jdk21 {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    $candidates += Get-ChildItem 'C:\Program Files\Microsoft\jdk-21*', 'C:\Program Files\Eclipse Adoptium\jdk-21*', 'C:\Program Files\Java\jdk-21*' `
        -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    foreach ($p in $candidates) {
        $release = Join-Path $p 'release'
        if ((Test-Path "$p\bin\java.exe") -and (Test-Path $release) -and ((Get-Content $release -Raw) -match 'JAVA_VERSION="21')) { return $p }
    }
    return $null
}

# Hash a file the way packwiz-installer sees it: text files as stored in git (LF line endings).
function Get-PackHash([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ([Array]::IndexOf($bytes, [byte]0) -lt 0) {
        $list = New-Object 'System.Collections.Generic.List[byte]' ($bytes.Length)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 13 -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
            $list.Add($bytes[$i])
        }
        $bytes = $list.ToArray()
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Write-Lf([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $Utf8)
}

# Sort key that compares the numbers in a file name as numbers (neoforge.9 < neoforge.54).
function Get-VersionKey([string]$Name) {
    return [regex]::Replace($Name, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Getting the latest pack from GitHub'
Invoke-Git pull --rebase --autostash origin main

foreach ($mod in $ModProjects) {
    if (-not (Test-Path (Join-Path $mod.Dir 'gradlew.bat'))) { continue }
    if (-not $NoBuild) {
        Write-Step "Building $($mod.Name)"
        $jdk = Find-Jdk21
        if (-not $jdk) { throw 'Java 21 (JDK) not found. Install it with: winget install Microsoft.OpenJDK.21' }
        $env:JAVA_HOME = $jdk
        Push-Location $mod.Dir
        try {
            & .\gradlew.bat build --console=plain
            if ($LASTEXITCODE -ne 0) {
                # OneDrive sometimes locks old build outputs ("Failed to clean up stale outputs"): clear them and retry once.
                Write-Host '  build failed, clearing build outputs and retrying...' -ForegroundColor Yellow
                foreach ($d in 'build\resources', 'build\generated\sources\modMetadata', 'build\libs') {
                    if (Test-Path $d) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
                }
                & .\gradlew.bat build --console=plain
                if ($LASTEXITCODE -ne 0) { throw "Building $($mod.Name) failed" }
            }
        } finally { Pop-Location }
    }
    $jar = Get-ChildItem (Join-Path $mod.Dir "build\libs\$($mod.Name)-*.jar") -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '-(sources|javadoc)\.jar$' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($jar) {
        $dest = Join-Path $Repo "files\$($jar.Name)"
        if (-not (Test-Path $dest) -or (Get-FileHash $dest).Hash -ne (Get-FileHash $jar.FullName).Hash) {
            Copy-Item $jar.FullName $dest -Force
            Write-Host "  copied $($jar.Name) into files/"
        }
    }
}

Write-Step 'Updating self-hosted mods (files/)'
foreach ($toml in Get-ChildItem (Join-Path $Repo 'mods\*.pw.toml')) {
    $text = [IO.File]::ReadAllText($toml.FullName)
    $m = [regex]::Match($text, '(?m)^url = "' + [regex]::Escape($RawBase) + 'files/([^"]+)"')
    if (-not $m.Success) { continue }
    $current = $m.Groups[1].Value
    $prefix = [regex]::Match($current, '^(.*?-)(?=\d)').Groups[1].Value
    if (-not $prefix) { $prefix = [IO.Path]::GetFileNameWithoutExtension($current) }
    $newest = Get-ChildItem (Join-Path $Repo 'files') -Filter "$prefix*.jar" |
        Sort-Object { Get-VersionKey $_.Name } -Descending | Select-Object -First 1
    if (-not $newest) { throw "No jar in files/ for $($toml.Name) (looked for $prefix*.jar)" }
    $hash = Get-PackHash $newest.FullName
    $text = [regex]::Replace($text, '(?m)^filename = ".*"', "filename = `"$($newest.Name)`"")
    $text = $text.Replace("files/$current`"", "files/$($newest.Name)`"")
    $text = [regex]::Replace($text, '(?m)^hash = "[0-9a-f]*"', "hash = `"$hash`"")
    Write-Lf $toml.FullName $text
    if ($current -ne $newest.Name) { Write-Host "  $($toml.Name): $current -> $($newest.Name)" }
    else { Write-Host "  $($toml.Name): $($newest.Name)" }
}

Write-Step 'Refreshing index.toml'
$indexPath = Join-Path $Repo 'index.toml'
$old = @{}
foreach ($block in ([IO.File]::ReadAllText($indexPath) -split '\[\[files\]\]') | Select-Object -Skip 1) {
    $f = [regex]::Match($block, '(?m)^file = "(.*)"').Groups[1].Value
    if ($f) { $old[$f] = @{ Metafile = $block -match '(?m)^metafile = true'; Preserve = $block -match '(?m)^preserve = true' } }
}
$entries = New-Object System.Collections.Generic.List[object]
foreach ($t in Get-ChildItem (Join-Path $Repo 'mods\*.pw.toml') | Sort-Object Name) {
    $entries.Add(@{ File = "mods/$($t.Name)"; Path = $t.FullName; Metafile = $true; Preserve = $false })
}
foreach ($dir in $IndexedDirs) {
    $full = Join-Path $Repo $dir
    if (-not (Test-Path $full)) { continue }
    foreach ($f in Get-ChildItem $full -Recurse -File | Sort-Object FullName) {
        $rel = $f.FullName.Substring($Repo.Length + 1).Replace('\', '/')
        $preserve = $old.ContainsKey($rel) -and $old[$rel].Preserve
        $entries.Add(@{ File = $rel; Path = $f.FullName; Metafile = $false; Preserve = $preserve })
    }
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("hash-format = `"sha256`"`n")
foreach ($e in $entries) {
    [void]$sb.Append("`n[[files]]`nfile = `"$($e.File)`"`nhash = `"$(Get-PackHash $e.Path)`"`n")
    if ($e.Metafile) { [void]$sb.Append("metafile = true`n") }
    if ($e.Preserve) { [void]$sb.Append("preserve = true`n") }
}
Write-Lf $indexPath $sb.ToString()
foreach ($k in $old.Keys) { if (-not ($entries | Where-Object { $_.File -eq $k })) { Write-Host "  removed $k (file is gone)" } }
Write-Host "  $($entries.Count) files indexed"

$packPath = Join-Path $Repo 'pack.toml'
function Set-PackHash {
    $p = [IO.File]::ReadAllText($packPath)
    $p = [regex]::Replace($p, '(?m)^hash = "[0-9a-f]*"', "hash = `"$(Get-PackHash $indexPath)`"")
    Write-Lf $packPath $p
}
Set-PackHash

$PackPaths = @('mods', 'files', 'index.toml', 'pack.toml') + ($IndexedDirs | Where-Object { Test-Path (Join-Path $Repo $_) })
$changes = & $Git -C $Repo status --porcelain -- @PackPaths
if (-not $changes) {
    Write-Step 'Nothing new to publish - the pack on GitHub is already up to date.'
    exit 0
}

$pack = [IO.File]::ReadAllText($packPath)
$currentVersion = [regex]::Match($pack, '(?m)^version = "(.*)"').Groups[1].Value
if (-not $Version) {
    $vm = [regex]::Match($currentVersion, '^(.*?)(\d+)$')
    $Version = if ($vm.Success) { $vm.Groups[1].Value + ([int]$vm.Groups[2].Value + 1) } else { "$currentVersion.1" }
}
Write-Step "Changes for $Version"
& $Git -C $Repo status --short -- @PackPaths

if ($NoPush) {
    Write-Step "Checked only (-NoPush): would publish as $Version. Nothing was committed or pushed."
    exit 0
}

Write-Lf $packPath ([regex]::Replace($pack, '(?m)^version = ".*"', "version = `"$Version`""))

Write-Step "Publishing $Version"
Invoke-Git add -A -- @PackPaths
Get-ChildItem $Repo -Filter 'update-pack.ps1' | ForEach-Object { Invoke-Git add -- $_.Name }
Get-ChildItem $Repo -Filter 'Update Pack.bat' | ForEach-Object { Invoke-Git add -- $_.Name }
& $Git -C $Repo -c user.name='Rift SMP updates' -c user.email='updates@users.noreply.github.com' commit -m "Update to $Version"
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
& $Git -C $Repo push origin main
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nPush failed. The update is committed locally: open GitHub Desktop and press 'Push origin'." -ForegroundColor Yellow
    exit 1
}
Write-Step "Done! Everyone gets $Version the next time they press Launch."
