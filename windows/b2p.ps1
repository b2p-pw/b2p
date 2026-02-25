param(
    [String]$install,
    [String]$uninstall,
    [String]$upgrade,
    [String]$default,
    [String]$search,
    [String]$v = "latest",
    [Switch]$s = $false,
    [Switch]$version           # show CLI/core version information
)

$B2P_CLI_VERSION = "1.5.1"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$RAW_B2P = "https://raw.githubusercontent.com/b2p-pw/b2p/main/windows"
$RAW_W   = "https://raw.githubusercontent.com/b2p-pw/windows-catalog/main"
$API_W   = "https://api.github.com/repos/b2p-pw/windows-catalog/contents"

$B2P_HOME = Join-Path $env:USERPROFILE ".b2p"
$B2P_APPS = Join-Path $B2P_HOME "apps"

# 1. Load local or remote core
$localCore = Join-Path $B2P_HOME "bin\core.ps1"
if (Test-Path $localCore) { . $localCore } else { . ([ScriptBlock]::Create((Invoke-RestMethod -Uri "$RAW_B2P/core.ps1"))) }

if (-not $B2P_BIN) {
    $B2P_BIN = Join-Path $B2P_HOME "bin"; $B2P_SHIMS = Join-Path $B2P_HOME "shims"
    $B2P_TELEPORTS = Join-Path $B2P_HOME "teleports"
}

# --- HELPERS ---
function Resolve-B2PVersion {
    param($App, $Ver)
    $appPath = Join-Path $B2P_APPS $App
    if ($Ver -eq "latest" -and (Test-Path $appPath)) {
        $latest = Get-ChildItem $appPath -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { return $latest.Name }
        Write-Host "[b2p] Warning: No versions found for $App. Using 'latest' as literal slot." -ForegroundColor Yellow
    }
    return $Ver
}

function Show-Header {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "    Binary-2-Path (b2p) CLI v$B2P_CLI_VERSION  " -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Magenta
}

# --- MENUS ---
function Show-Catalog {
    param([String]$filter = "")
    Show-Header
    Write-Host "Fetching catalog from W repository..." -ForegroundColor Gray
    try {
        $items = Invoke-RestMethod -Uri $API_W -UserAgent "b2p"
        $apps = @($items | Where-Object { $_.type -eq "dir" -and $_.name -like "*$filter*" } | Select-Object -ExpandProperty name)
        if ($apps.Count -eq 0) { Write-Host "No apps found." -ForegroundColor Yellow }
        else {
            Write-Host "`nAvailable for installation:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $apps.Count; $i++) { " [{0,2}] {1}" -f ($i + 1), $apps[$i] }
        }
        Write-Host " [ Q] Back" -ForegroundColor Yellow
        $choice = Read-Host "`nSelect"
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $apps.Count) {
            $selected = $apps[$idx - 1]
            $url = "$RAW_W/$selected/i.s"
            Write-B2PAudit "Installing app from: $url"
            Invoke-B2PRemoteScript -Uri $url -ArgumentList "-v latest"
            Read-Host "`nProcess finished. Press Enter..."
        }
    } catch { Write-Host "Connection error." -ForegroundColor Red; Pause }
}

function Manage-Installed {
    Show-Header
    if (-not (Test-Path $B2P_APPS)) { Write-Host "No installed apps." -ForegroundColor Yellow; Pause; return }
    $installedApps = @(Get-ChildItem $B2P_APPS -Directory)
    if ($installedApps.Count -eq 0) { Write-Host "No installed apps." -ForegroundColor Yellow; Pause; return }
    
    Write-Host "`nInstalled applications:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $installedApps.Count; $i++) { " [{0,2}] {1}" -f ($i + 1), $installedApps[$i].Name }
    Write-Host " [ Q] Back" -ForegroundColor Yellow

    $choice = Read-Host "`nSelect an app"
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $installedApps.Count) {
        $app = $installedApps[$idx - 1].Name
        $versions = @(Get-ChildItem (Join-Path $B2P_APPS $app) -Directory | Select-Object -ExpandProperty Name)
        
        Show-Header
        Write-Host "Managing: $app" -ForegroundColor Cyan
        Write-Host "Versions: $($versions -join ', ')" -ForegroundColor Gray
        Write-Host "`n [1] Upgrade"
        Write-Host " [2] Set Default Version"
        Write-Host " [3] Create Custom Shim"
        Write-Host " [4] Set System PATH"
        Write-Host " [5] Unset System PATH"
        Write-Host " [6] Uninstall"
        Write-Host " [Q] Back"

        switch (Read-Host "`nOption") {
            "1" { Write-B2PAudit "Upgrading: $app"; Invoke-B2PRemoteScript -Uri "$RAW_W/$app/up.s" }
            "2" {
                $verIn = Read-Host "Desired version"
                $verReal = Resolve-B2PVersion -App $app -Ver $verIn
                if (Set-B2PLatestLink -AppName $app -TargetVersion $verReal) {
                    Write-B2PAudit "Set default version for $app to $verReal"
                    Write-Host "Default version updated to $verReal!" -ForegroundColor Green
                } else {
                    Write-Host "Failed to set default version" -ForegroundColor Red
                }
            }
            "3" {
                $shimName = Read-Host "Custom shim name (alias)"
                if (-not (Test-ValidFileName -Name $shimName -Type "shim name")) { return }
                
                $binName = Read-Host "Binary name in bin folder"
                if (-not (Test-ValidFileName -Name $binName -Type "binary name")) { return }
                
                $verIn = Read-Host "Version to link (or 'latest')"
                $verReal = Resolve-B2PVersion -App $app -Ver $verIn
                $binPath = Join-Path $B2P_APPS "$app\$verReal\$binName"
                if (Test-Path $binPath) {
                    $shimPath = Join-Path $B2P_SHIMS "$shimName.bat"
                    "@`"$binPath`" %*" | Out-File $shimPath -Encoding UTF8
                    Write-B2PAudit "Created shim: $shimName -> $binPath"
                    Write-Host "Shim '$shimName' created" -ForegroundColor Green
                } else { Write-Host "Binary not found at $binPath" -ForegroundColor Red }
            }
            "4" { Update-B2PPath -Action "Add" -Scope "User" }
            "5" { Update-B2PPath -Action "Remove" -Scope "User" }
            "6" { 
                $ver = Read-Host "Version or 'all'"
                $verReal = Resolve-B2PVersion -App $app -Ver $ver
                $localUn = Join-Path $B2P_APPS "$app\$verReal\uninstall.ps1"
                Write-B2PAudit "Uninstalling: $app ($ver)"
                if (Test-Path $localUn) {
                    $tempUn = Join-Path $env:TEMP "b2p-un-$app.ps1"
                    Copy-Item $localUn $tempUn -Force
                    powershell -NoProfile -File $tempUn -Name $app -Version $ver
                    Remove-Item $tempUn -ErrorAction SilentlyContinue
                } else { 
                    Invoke-B2PRemoteScript -Uri "$RAW_W/$app/un.s"
                }
            }
        }
        Read-Host "`nDone. Press Enter..."
    }
}

# --- CLI ROUTING ---

# version switch is evaluated first because it's a no-op that just prints info
if ($version) {
    Write-Host "b2p CLI version $B2P_CLI_VERSION" -ForegroundColor Cyan
    if ($B2P_CORE_VERSION) { Write-Host "b2p core version $B2P_CORE_VERSION" -ForegroundColor Cyan }
    return
}

function Setup-B2P-Self {
    # install or update the CLI itself (b2p.ps1 + core.ps1)
    Write-B2PAudit "Self-install invoked"
    Write-Host "[b2p] Installing/updating b2p CLI and core..." -ForegroundColor Cyan
    try {
        if (-not (Test-Path $B2P_BIN)) { New-Item -Path $B2P_BIN -ItemType Directory -Force | Out-Null }
        $cliDest  = Join-Path $B2P_BIN "b2p.ps1"
        $coreDest = Join-Path $B2P_BIN "core.ps1"
        Invoke-WebRequest -Uri "$RAW_B2P/b2p.ps1"  -OutFile $cliDest  -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "$RAW_B2P/core.ps1" -OutFile $coreDest -UseBasicParsing -ErrorAction Stop
        Write-B2PAudit "Self-install successful"
        Write-Host "[b2p] CLI updated. Restart your shell or rerun the command to pick up changes." -ForegroundColor Green
    } catch {
        Write-B2PAudit "Self-install failed: $_" "ERROR"
        Write-Host "[b2p] Self-install failed: $_" -ForegroundColor Red
    }
}

if ($install) { 
    if ($install -eq "b2p") { Setup-B2P-Self } 
    else { 
        $sf = if ($s) { "-s" } else { "" }
        $url = "$RAW_W/$install/i.s"
        Write-B2PAudit "CLI install: $install"
        try {
            Invoke-B2PRemoteScript -Uri $url -ArgumentList "-v '$v' $sf"
        } catch {
            Write-Host "Installation failed: $_" -ForegroundColor Red
            Write-B2PAudit "Installation failed: $_" "ERROR"
        }
    }
    return 
}

if ($uninstall) {
    $verReal = Resolve-B2PVersion -App $uninstall -Ver $v
    $localUn = Join-Path $B2P_APPS "$uninstall\$verReal\uninstall.ps1"
    Write-B2PAudit "CLI uninstall: $uninstall ($v)"
    try {
        if (Test-Path $localUn) {
            $tempUn = Join-Path $env:TEMP "b2p-un-$uninstall.ps1"
            Copy-Item $localUn $tempUn -Force
            powershell -NoProfile -File $tempUn -Name $uninstall -Version $v
            Remove-Item $tempUn -ErrorAction SilentlyContinue
        } else {
            Invoke-B2PRemoteScript -Uri "$RAW_W/$uninstall/un.s"
        }
    } catch {
        Write-Host "Uninstall failed: $_" -ForegroundColor Red
        Write-B2PAudit "Uninstall failed: $_" "ERROR"
    }
    return
}

if ($upgrade) { 
    if ($upgrade -eq "b2p") { 
        Setup-B2P-Self
        return
    }

    Write-B2PAudit "CLI upgrade: $upgrade"
    try {
        Invoke-B2PRemoteScript -Uri "$RAW_W/$upgrade/up.s" -ArgumentList $(if($s){'-s'})
    } catch {
        Write-Host "Upgrade failed: $_" -ForegroundColor Red
        Write-B2PAudit "Upgrade failed: $_" "ERROR"
    }
    return 
}

function Show-System-Tools {
    Show-Header
    Write-Host "`n[b2p] System Tools:" -ForegroundColor Cyan
    Write-Host " [1] Doctor (verify environment)"
    Write-Host " [2] Update b2p core"
    Write-Host " [Q] Back"

    $choice = Read-Host "`nOption"
    switch ($choice) {
        "1" {
            Write-Host "`n[b2p] Running doctor..." -ForegroundColor Gray
            foreach ($path in @($B2P_HOME, $B2P_APPS, $B2P_TELEPORTS, $B2P_SHIMS, $B2P_BIN)) {
                if (-not (Test-Path $path)) {
                    Write-Host "Missing $path" -ForegroundColor Yellow
                } else {
                    Write-Host "Found $path" -ForegroundColor Green
                }
            }
            Pause
        }
        "2" {
            Write-Host "`n[b2p] Updating core script..." -ForegroundColor Gray
            try {
                Invoke-WebRequest -Uri "$RAW_B2P/core.ps1" -OutFile (Join-Path $B2P_HOME "bin\core.ps1") -UseBasicParsing
                Write-Host "Core updated." -ForegroundColor Green
            } catch {
                Write-Host "Update failed: $_" -ForegroundColor Red
            }
            Pause
        }
    }
}

# --- MAIN MENU ---
while ($true) {
    Show-Header
    Write-Host " [1] Browse Apps"
    Write-Host " [2] Search App"
    Write-Host " [3] Manage Installed"
    Write-Host " [4] System (Doctor/Update)"
    Write-Host " [0] Exit"
    switch (Read-Host "`nChoice") {
        "1" { Show-Catalog }
        "2" { $q = Read-Host "Search"; Show-Catalog -filter $q }
        "3" { Manage-Installed }
        "4" { Show-System-Tools }
        "0" { exit }
    }
}