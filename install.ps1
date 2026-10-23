# odinup bootstrap for Windows - from a bare machine to a working Odin.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/voxiverse/odinup/main/install.ps1 | iex"
#
# What it does (each step is skipped when already done, so re-running is safe):
#   1. git: uses yours, else installs Git for Windows with winget (it includes
#      Git LFS, which Odin's repository uses for some vendor libraries).
#   2. MSVC: uses an installed Visual Studio with the C++ tools, else downloads
#      just the compiler + Windows SDK from Microsoft into ~\.odinup\msvc
#      ("portable MSVC": no Visual Studio installer, no admin, no UAC prompt).
#      You are asked to accept Microsoft's license first.
#   3. Clones Odin to ~\.odinup\odin and builds the pinned or latest dev-* tag.
#   4. Builds odinup.exe with it and hands over to `odinup install`, which
#      writes odin.exe / ols.exe shims to ~\.odinup\bin.
#   5. Adds ~\.odinup\bin to your user PATH (and to this session).
#
# Environment:
#   $env:ODINUP_ODIN_VERSION = "dev-2026-07"   build this Odin tag instead of the latest
#   $env:ODINUP_REPO / $env:ODINUP_REF         where to get odinup's source (default: GitHub, main)
#   $env:ODINUP_MSVC = "portable" | "vs"       force portable MSVC / an installed Visual Studio
#   $env:ODINUP_ACCEPT_MSVC_LICENSE = "1"      accept the MSVC license without the y/n prompt
#
# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less scripts as
# cp1252, where UTF-8 punctuation can turn into quote characters.

# Everything runs inside a script block: preferences stay local to it, and
# errors are thrown rather than `exit`ed - under `irm | iex`, `exit` would
# close the user's PowerShell window.
& {
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # the progress bar slows downloads ~10x on PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$DestDir   = Join-Path $env:USERPROFILE ".odinup"
$OdinDir   = Join-Path $DestDir "odin"
$BinDir    = Join-Path $DestDir "bin"
$StateDir  = Join-Path $DestDir "state"
$OdinRepo  = "https://github.com/odin-lang/Odin"
$Repo      = if ($env:ODINUP_REPO) { $env:ODINUP_REPO } else { "https://github.com/voxiverse/odinup" }
$Ref       = if ($env:ODINUP_REF) { $env:ODINUP_REF } else { "main" }
$MsvcDir   = Join-Path $DestDir "msvc"
$ChannelUrl = "https://aka.ms/vs/17/release/channel"
$OdinExe   = Join-Path $OdinDir "odin.exe"

function Log($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Die($m)  { throw "odinup: $m" }

# Native commands don't throw on failure; check the exit code. Quote any
# -flag:value argument: PowerShell binds it as a parameter and drops "-flag:".
function Invoke-Checked {
    $exe, $rest = $args
    & $exe @rest
    if ($LASTEXITCODE -ne 0) { Die "'$exe $($rest -join ' ')' failed (exit $LASTEXITCODE)" }
}

# Update-SessionPath adds new entries from the registry PATH (machine, then
# user) to this session's, so programs installed by this script (winget) are
# usable right away; entries only this session has are kept.
function Update-SessionPath {
    $have = @($env:PATH -split ";" | Where-Object { $_ })
    foreach ($scope in "Machine", "User") {
        foreach ($p in ([Environment]::GetEnvironmentVariable("Path", $scope) -split ";")) {
            if ($p -and $have -notcontains $p) { $have += $p }
        }
    }
    $env:PATH = $have -join ";"
}

# Remove-FromUserPath drops $dir from the user PATH (registry and session).
function Remove-FromUserPath($dir) {
    $env:PATH = (($env:PATH -split ";") | Where-Object { $_ -and $_ -ne $dir }) -join ";"
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    try {
        $cur = $key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($cur -split ";" | Where-Object { $_ -and $_ -ne $dir })
        if ($parts.Count -ne @($cur -split ";" | Where-Object { $_ }).Count) {
            $key.SetValue("Path", ($parts -join ";"), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        }
    } finally { $key.Close() }
}

# Add-ToUserPath persists $dir in the user PATH (registry, keeping
# REG_EXPAND_SZ so %VARS% in existing entries survive) and this session.
function Add-ToUserPath($dir) {
    if (($env:PATH -split ";") -notcontains $dir) { $env:PATH = "$dir;$env:PATH" }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    try {
        $cur = $key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (($cur -split ";") -contains $dir) { return }
        $new = if ($cur) { "$dir;$cur" } else { $dir }
        $key.SetValue("Path", $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
    # Setting any user variable broadcasts WM_SETTINGCHANGE, so terminals
    # started from Explorer from now on see the new PATH without a re-login.
    [Environment]::SetEnvironmentVariable("ODINUP_PATH_REFRESH", "1", "User")
    [Environment]::SetEnvironmentVariable("ODINUP_PATH_REFRESH", $null, "User")
    Ok "Added $dir to your user PATH"
}

# QuickEdit: with it on (the default), clicking in the console starts a
# selection that freezes all output until a key is pressed - a finished
# build then looks hung. Off while we run; put back at the end.
$quickEdit = $null
try {
    if (-not ([System.Management.Automation.PSTypeName]'OdinupConsole.Native').Type) {
        Add-Type -Namespace OdinupConsole -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
'@
    }
    $stdin = [OdinupConsole.Native]::GetStdHandle(-10)
    $mode = [uint32]0
    if ([OdinupConsole.Native]::GetConsoleMode($stdin, [ref]$mode)) {
        $off = ($mode -band [uint32]4294967231) -bor [uint32]128   # clear QUICK_EDIT (0x40), set EXTENDED_FLAGS (0x80)
        if ([OdinupConsole.Native]::SetConsoleMode($stdin, $off)) { $quickEdit = $mode }
    }
} catch { }

# ---------------------------------------------------------------- platform
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($arch -ne "AMD64") { Warn "This machine is $arch; odinup is tested on x64 (AMD64) Windows only." }
Log "odinup bootstrap (Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion))"
New-Item -ItemType Directory -Force -Path $DestDir, $BinDir, $StateDir | Out-Null

# --------------------------------------------------------------------- git
# Git for Windows (includes Git LFS: Odin keeps some vendor libraries in it),
# installed with winget when there is no git. odinup 1.0 used a portable
# MinGit without Git LFS, which breaks Odin's checkout: retire it.
$oldMinGit = Join-Path $DestDir "git"
$oldMinGitCmd = Join-Path $oldMinGit "cmd"
Remove-FromUserPath $oldMinGitCmd
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die "Git is not installed and winget is not available. Install Git for Windows from https://git-scm.com/download/win, then re-run this installer."
    }
    Log "Installing Git for Windows with winget..."
    $wingetArgs = @("install", "--id", "Git.Git", "--exact", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity")
    & winget @wingetArgs --scope user
    Update-SessionPath
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        # No per-user installer on this machine: install for all users (Windows asks to confirm).
        & winget @wingetArgs
        Update-SessionPath
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Die "Installing Git with winget did not work (see above). Install Git for Windows from https://git-scm.com/download/win, then re-run this installer."
    }
}
Ok "git: $((Get-Command git).Source)"
# Through cmd: redirecting a native command's stderr in PS 5.1 can throw.
& cmd.exe /d /c "git lfs version >nul 2>nul"
if ($LASTEXITCODE -eq 0) { Ok "git-lfs present" } else { Warn "git-lfs is missing: Odin's vendor:box2d/box3d will lack their libraries (Git for Windows includes it)" }
if (Test-Path $oldMinGit) { Remove-Item -Recurse -Force $oldMinGit -ErrorAction SilentlyContinue }

# -------------------------------------------------------------------- MSVC
# Odin needs Microsoft's compiler to build itself and Microsoft's linker,
# C runtime and Windows SDK libraries to link every program. An installed
# Visual Studio provides them; otherwise we fetch only those packages from
# the same feed the Visual Studio installer uses (like mmozeiko's
# portable-msvc), into ~\.odinup\msvc. Odin finds that toolchain through the
# environment variables in msvc\env.txt, which the odin.exe shim sets.

function Find-VcVars64 {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $paths = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        foreach ($p in @($paths)) {
            if (-not $p) { continue }
            $vcvars = Join-Path $p "VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $vcvars) { return $vcvars }
        }
    }
    foreach ($year in "18", "2022") {
        foreach ($edition in "BuildTools", "Community", "Professional", "Enterprise") {
            $c = Join-Path $env:ProgramFiles "Microsoft Visual Studio\$year\$edition\VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $c) { return $c }
        }
    }
    return $null
}

# Read-JsonFile parses JSON into dictionaries. The VS manifest is tens of MB;
# PS 5.1's ConvertFrom-Json is slow and size-limited on that, so use .NET's
# serializer there.
function Read-JsonFile($path) {
    $text = [IO.File]::ReadAllText($path)
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ($text | ConvertFrom-Json -AsHashtable) }
    Add-Type -AssemblyName System.Web.Extensions
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    return $js.DeserializeObject($text)
}

function Save-Verified($url, $sha256, $out) {
    if ((Test-Path $out) -and $sha256 -and (Get-FileHash -Algorithm SHA256 $out).Hash -eq $sha256) { return }
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out
    if ($sha256 -and (Get-FileHash -Algorithm SHA256 $out).Hash -ne $sha256) {
        Remove-Item -Force $out
        Die "Checksum mismatch downloading $url - re-run to retry."
    }
}

# Expand-Vsix extracts a .vsix (zip) package's Contents/ folder into $dest.
function Expand-Vsix($zipPath, $dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($e in $zip.Entries) {
            $name = [Uri]::UnescapeDataString($e.FullName)
            if (-not $name.StartsWith("Contents/") -or $name.EndsWith("/")) { continue }
            $rel = $name.Substring("Contents/".Length)
            if ($rel -match '(^|[\\/])\.\.([\\/]|$)') { continue }
            $out = Join-Path $dest $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
        }
    } finally { $zip.Dispose() }
}

function Get-Newest($dir) {
    Get-ChildItem -Directory $dir | Where-Object { $_.Name -as [version] } |
        Sort-Object { [version]$_.Name } | Select-Object -Last 1 -ExpandProperty Name
}

function Install-PortableMsvc {
    $dl = Join-Path $MsvcDir ".downloads"
    New-Item -ItemType Directory -Force -Path $dl | Out-Null

    Log "Reading Microsoft's package manifest"
    $channelFile = Join-Path $dl "channel.json"
    Invoke-WebRequest -UseBasicParsing -Uri $ChannelUrl -OutFile $channelFile
    $channel = Read-JsonFile $channelFile
    $items = @($channel["channelItems"])
    $buildTools = $items | Where-Object { $_["id"] -eq "Microsoft.VisualStudio.Product.BuildTools" } | Select-Object -First 1
    $license = ($buildTools["localizedResources"] | Where-Object { $_["language"] -eq "en-us" } | Select-Object -First 1)["license"]

    Write-Host ""
    Write-Host "  odinup will download Microsoft's C/C++ compiler and the Windows SDK"
    Write-Host "  (no Visual Studio install, no admin rights). They are covered by the"
    Write-Host "  Visual Studio Build Tools license:"
    Write-Host "    $license" -ForegroundColor White
    Write-Host ""
    if ($env:ODINUP_ACCEPT_MSVC_LICENSE -eq "1") {
        Ok "License accepted via ODINUP_ACCEPT_MSVC_LICENSE=1"
    } else {
        $answer = Read-Host "  Accept the license and continue? [y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Die "License not accepted. Install Visual Studio with 'Desktop development with C++' instead, or re-run and answer y."
        }
    }

    $vsItem = $items | Where-Object { $_["id"] -eq "Microsoft.VisualStudio.Manifests.VisualStudio" } | Select-Object -First 1
    $manifestFile = Join-Path $dl "vs.json"
    Invoke-WebRequest -UseBasicParsing -Uri $vsItem["payloads"][0]["url"] -OutFile $manifestFile
    $manifest = Read-JsonFile $manifestFile

    $pkgs = @{}   # lowercase id -> package entries (one per language/variant)
    foreach ($p in $manifest["packages"]) {
        $id = $p["id"].ToLowerInvariant()
        if (-not $pkgs.ContainsKey($id)) { $pkgs[$id] = New-Object System.Collections.ArrayList }
        [void]$pkgs[$id].Add($p)
    }

    # Newest MSVC toolset and Windows SDK, by their VS component ids.
    $msvcVer = $null; $sdkId = $null; $sdkBuild = 0
    foreach ($id in $pkgs.Keys) {
        if ($id -match '^microsoft\.visualstudio\.component\.vc\.(\d+(?:\.\d+)+)\.x86\.x64$') {
            if (-not $msvcVer -or [version]$Matches[1] -gt [version]$msvcVer) { $msvcVer = $Matches[1] }
        } elseif ($id -match '^microsoft\.visualstudio\.component\.windows1[01]sdk\.(\d+)$') {
            if ([int]$Matches[1] -gt $sdkBuild) { $sdkBuild = [int]$Matches[1]; $sdkId = $id }
        }
    }
    if (-not $msvcVer -or -not $sdkId) { Die "Could not find MSVC / Windows SDK packages in Microsoft's manifest." }
    Log "Downloading MSVC $msvcVer and Windows SDK 10.0.$sdkBuild"

    # MSVC: .vsix packages (zips) for x64-hosted, x64-targeting tools.
    foreach ($suffix in "crt.headers.base", "asan.headers.base", "pgo.headers.base",
                        "tools.hostx64.targetx64.base", "tools.hostx64.targetx64.res.base",
                        "crt.x64.desktop.base", "crt.x64.store.base",
                        "premium.tools.hostx64.targetx64.base", "pgo.x64.base") {
        $id = "microsoft.vc.$msvcVer.$suffix"
        if (-not $pkgs.ContainsKey($id)) { Warn "MSVC package $id not in manifest - skipping"; continue }
        $pkg = $pkgs[$id] | Where-Object { -not $_.ContainsKey("language") -or $_["language"] -in "en-US", "neutral" } | Select-Object -First 1
        foreach ($pl in $pkg["payloads"]) {
            $file = Join-Path $dl ($id + "-" + (Split-Path -Leaf $pl["fileName"]))
            Save-Verified $pl["url"] $pl["sha256"] $file
            Expand-Vsix $file $MsvcDir
        }
    }

    # Windows SDK: .msi installers plus the .cab files each one names,
    # unpacked with an administrative install (msiexec /a: no admin needed).
    $sdkPkgId = @($pkgs[$sdkId][0]["dependencies"].Keys)[0].ToLowerInvariant()
    $payloads = @{}
    foreach ($pl in $pkgs[$sdkPkgId][0]["payloads"]) { $payloads[$pl["fileName"]] = $pl }
    $sdkDl = Join-Path $dl "sdk"
    New-Item -ItemType Directory -Force -Path $sdkDl | Out-Null
    $msis = @(); $cabs = @{}
    foreach ($name in "Windows SDK for Windows Store Apps Tools-x86_en-us.msi",
                      "Windows SDK for Windows Store Apps Headers-x86_en-us.msi",
                      "Windows SDK for Windows Store Apps Headers OnecoreUap-x86_en-us.msi",
                      "Windows SDK for Windows Store Apps Libs-x86_en-us.msi",
                      "Universal CRT Headers Libraries and Sources-x86_en-us.msi",
                      "Windows SDK Desktop Headers x86-x86_en-us.msi",
                      "Windows SDK Desktop Headers x64-x86_en-us.msi",
                      "Windows SDK OnecoreUap Headers x86-x86_en-us.msi",
                      "Windows SDK OnecoreUap Headers x64-x86_en-us.msi",
                      "Windows SDK Desktop Libs x64-x86_en-us.msi") {
        $pl = $payloads["Installers\$name"]
        if (-not $pl) { Warn "SDK installer '$name' not in manifest - skipping"; continue }
        $msi = Join-Path $sdkDl $name
        Save-Verified $pl["url"] $pl["sha256"] $msi
        $msis += $msi
        $bytes = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($msi))
        foreach ($m in [regex]::Matches($bytes, '[0-9A-Za-z]{32}\.cab')) { $cabs[$m.Value] = $true }
    }
    foreach ($cab in $cabs.Keys) {
        $pl = $payloads["Installers\$cab"]
        if ($pl) { Save-Verified $pl["url"] $pl["sha256"] (Join-Path $sdkDl $cab) }
    }
    foreach ($msi in $msis) {
        $p = Start-Process -FilePath msiexec.exe -Wait -PassThru -ArgumentList "/a", "`"$msi`"", "/quiet", "/qn", "TARGETDIR=`"$MsvcDir`""
        if ($p.ExitCode -ne 0) { Die "Unpacking $(Split-Path -Leaf $msi) failed (msiexec exit $($p.ExitCode))." }
        Remove-Item -Force (Join-Path $MsvcDir (Split-Path -Leaf $msi)) -ErrorAction SilentlyContinue
    }

    $mb = [int]((Get-ChildItem -Recurse -File $dl | Measure-Object -Sum Length).Sum / 1MB)
    Remove-Item -Recurse -Force $dl
    Ok "Downloaded $mb MB"
}

# Write-MsvcEnv checks the portable toolchain is complete and writes
# msvc\env.txt (read by the odin.exe shim) and msvc\setup.bat (for cmd builds:
# `call %USERPROFILE%\.odinup\msvc\setup.bat`, like vcvars64.bat).
function Write-MsvcEnv {
    $vcVer = Get-Newest (Join-Path $MsvcDir "VC\Tools\MSVC")
    $kits = Join-Path $MsvcDir "Windows Kits\10"
    $sdkVer = Get-Newest (Join-Path $kits "Lib")
    if (-not $vcVer -or -not $sdkVer) { Die "Portable MSVC in $MsvcDir is incomplete - delete that folder and re-run." }
    $vc = Join-Path $MsvcDir "VC\Tools\MSVC\$vcVer"
    foreach ($f in "$vc\bin\Hostx64\x64\cl.exe", "$vc\bin\Hostx64\x64\link.exe", "$vc\lib\x64\libcmt.lib",
                   "$kits\Lib\$sdkVer\um\x64\kernel32.lib", "$kits\Lib\$sdkVer\ucrt\x64\ucrt.lib",
                   "$kits\Include\$sdkVer\um\windows.h", "$kits\bin\$sdkVer\x64\rc.exe", "$kits\bin\$sdkVer\x64\mt.exe") {
        if (-not (Test-Path $f)) { Die "Portable MSVC is missing $f - delete $MsvcDir and re-run." }
    }
    $vars = [ordered]@{
        VCToolsInstallDir  = "$vc\"
        WindowsSdkDir      = "$kits\"
        UniversalCRTSdkDir = "$kits\"
        WindowsSDKVersion  = "$sdkVer\"
    }
    $envLines = $vars.Keys | ForEach-Object { "$_=$($vars[$_])" }
    $inc = "$vc\include;$kits\Include\$sdkVer\ucrt;$kits\Include\$sdkVer\shared;$kits\Include\$sdkVer\um;$kits\Include\$sdkVer\winrt;$kits\Include\$sdkVer\cppwinrt"
    $lib = "$vc\lib\x64;$kits\Lib\$sdkVer\ucrt\x64;$kits\Lib\$sdkVer\um\x64"
    $path = "$vc\bin\Hostx64\x64;$kits\bin\$sdkVer\x64;$kits\bin\$sdkVer\x64\ucrt"
    $bat = @("@echo off", "rem odinup portable MSVC $vcVer / Windows SDK $sdkVer (x64)") +
           ($vars.Keys | ForEach-Object { "set `"$_=$($vars[$_])`"" }) +
           @("set `"INCLUDE=$inc`"", "set `"LIB=$lib`"", "set `"PATH=$path;%PATH%`"",
             # As vcvars64.bat sets them; Odin's build.bat checks the target arch.
             "set VSCMD_ARG_HOST_ARCH=x64", "set VSCMD_ARG_TGT_ARCH=x64")
    Set-Content -Path (Join-Path $MsvcDir "setup.bat") -Encoding ASCII -Value ($bat -join "`r`n")
    # env.txt last: its presence marks a complete install.
    Set-Content -Path (Join-Path $MsvcDir "env.txt") -Encoding ASCII -Value ($envLines -join "`r`n")
    Ok "Portable MSVC $vcVer, Windows SDK $sdkVer"
}

$mode = $env:ODINUP_MSVC
$portableReady = Test-Path (Join-Path $MsvcDir "env.txt")
$vcvars = $null
if ($mode -eq "vs") {
    $vcvars = Find-VcVars64
    if (-not $vcvars) { Die "ODINUP_MSVC=vs, but no Visual Studio with the C++ tools was found." }
} elseif ($mode -ne "portable" -and -not $portableReady) {
    $vcvars = Find-VcVars64
}
if ($vcvars) {
    Ok "MSVC: $vcvars"
} else {
    if (-not $portableReady) { Install-PortableMsvc }
    Write-MsvcEnv
    $vcvars = Join-Path $MsvcDir "setup.bat"
    Ok "MSVC: $vcvars"
}

# With portable MSVC, a directly run odin.exe (not via the shim) only finds the
# linker through these variables. Set them only around such runs (restored at
# the end) so this PowerShell session isn't left changed.
$msvcVars = @{}
if ($vcvars -eq (Join-Path $MsvcDir "setup.bat")) {
    foreach ($line in Get-Content (Join-Path $MsvcDir "env.txt")) {
        $k, $v = $line -split "=", 2
        if ($k) { $msvcVars[$k] = $v }
    }
}
$savedVars = @{}
foreach ($k in $msvcVars.Keys) {
    $savedVars[$k] = [Environment]::GetEnvironmentVariable($k)
    [Environment]::SetEnvironmentVariable($k, $msvcVars[$k])
}
try {

# -------------------------------------------------------------------- Odin
# LFS files are checked out as pointers whatever the git; `odinup install`
# then fetches the real ones (git lfs pull).
$NoLfs = @("-c", "filter.lfs.smudge=", "-c", "filter.lfs.process=", "-c", "filter.lfs.required=false")
if (Test-Path (Join-Path $OdinDir ".git")) {
    Log "Fetching Odin updates"
    & git -C $OdinDir fetch --tags --force --prune origin
    if ($LASTEXITCODE -ne 0) { Warn "fetch failed - using local tags" }
} else {
    if (Test-Path $OdinDir) { Remove-Item -Recurse -Force $OdinDir }
    Log "Cloning Odin..."
    Invoke-Checked git @NoLfs clone $OdinRepo $OdinDir
}

$tag = $env:ODINUP_ODIN_VERSION
if (-not $tag) {
    $tag = @(& git -C $OdinDir tag -l "dev-*" | Where-Object { $_ -cmatch '^dev-\d{4}-\d{2}[a-z]?$' } | Sort-Object -CaseSensitive)[-1]
    if (-not $tag) { Die "Could not find any dev-* tag in $OdinDir." }
}
Log "Odin $tag"
$want = & git -C $OdinDir rev-parse --verify --quiet "$tag^{commit}"
if ($LASTEXITCODE -ne 0 -or -not $want) { Die "Odin tag '$tag' not found." }
Invoke-Checked git -C $OdinDir @NoLfs checkout --quiet --force --detach $want

# Skip the multi-minute build when this commit is already built.
$built = $false
if (Test-Path $OdinExe) {
    $ver = (& $OdinExe version) -join " "
    if ($ver -match ':([0-9a-f]{7,})') { $built = $want.StartsWith($Matches[1]) }
}
if ($built) {
    Ok "Odin $tag already built"
} else {
    Log "Building Odin from source - this takes a few minutes..."
    # Through a .bat: quoted paths inside `cmd /c "..."` don't survive PS 5.1's argument passing.
    $bat = Join-Path $StateDir "bootstrap.bat"
    Set-Content -Path $bat -Encoding ASCII -Value "@echo off`r`ncall `"$vcvars`" || exit /b 1`r`ncd /d `"$OdinDir`" || exit /b 1`r`ncall build.bat release`r`nexit /b %ERRORLEVEL%"
    & cmd.exe /d /c $bat
    $code = $LASTEXITCODE
    Remove-Item -Force $bat
    if ($code -ne 0 -or -not (Test-Path $OdinExe)) { Die "Building Odin failed (see output above)." }
    Ok "Built $((& $OdinExe version) -join ' ')"
}

# ------------------------------------------------------------------ odinup
# Source: this checkout when run from one, else a clone of $Repo at $Ref.
$src = $null
if ($PSCommandPath) {
    $here = Split-Path -Parent $PSCommandPath
    if (Test-Path (Join-Path $here "src\main.odin")) { $src = $here }
}
if (-not $src) {
    $src = Join-Path $DestDir "src"
    if (Test-Path (Join-Path $src ".git")) {
        & git -C $src fetch --quiet --tags --force origin
        if ($LASTEXITCODE -ne 0) { Warn "could not update $src" }
    } else {
        if (Test-Path $src) { Remove-Item -Recurse -Force $src }
        Invoke-Checked git -c advice.detachedHead=false clone --quiet $Repo $src
    }
    # Probe quietly: under PS 5.1 with ErrorActionPreference=Stop, redirecting a
    # native command's stderr (2>$null) turns any stderr output into a terminating error.
    $co = if (& git -C $src rev-parse --verify --quiet "origin/$Ref^{commit}") { "origin/$Ref" } else { $Ref }
    Invoke-Checked git -C $src checkout --quiet --force --detach $co
}
Log "Building odinup from $src"
$odinup = Join-Path $BinDir "odinup.exe"
Invoke-Checked $OdinExe build (Join-Path $src "src") "-o:speed" "-out:$odinup"
Ok "Built $(& $odinup version)"

# Hand over: odinup writes the odin.exe shim (no rebuild - the commit is
# built). Run from ~\.odinup so a project's odinup.toml in the current
# directory doesn't change what gets installed.
Push-Location $DestDir
try { Invoke-Checked $odinup install --odin $tag } finally { Pop-Location }
Remove-Item -Force (Join-Path $BinDir "odin.bat") -ErrorAction SilentlyContinue   # .bat shim from older odinup
} finally {
    foreach ($k in $savedVars.Keys) { [Environment]::SetEnvironmentVariable($k, $savedVars[$k]) }
}

Add-ToUserPath $BinDir

Write-Host ""
Ok "Odin is installed: $((& (Join-Path $BinDir 'odin.exe') version) -join ' ')"
Write-Host ""
Write-Host "  This window is ready to use. Other open terminals need a restart"
Write-Host "  (Windows Terminal: close all of its windows)."
Write-Host ""
Write-Host "  In a project with an odinup.toml:  odinup install   (--dev: also its dev tools, e.g. ols)"
if ($msvcVars.Count) {
    Write-Host "  To compile C code with MSVC (cl, link):  call %USERPROFILE%\.odinup\msvc\setup.bat"
}
Write-Host ""
if ($null -ne $quickEdit) { [void][OdinupConsole.Native]::SetConsoleMode([OdinupConsole.Native]::GetStdHandle(-10), $quickEdit) }
}
