param([String]$install, [String]$uninstall, [String]$upgrade, [String]$default, [String]$search, [String]$v = "latest", [Switch]$s = $false)

$B2P_CLI_VERSION = "1.5.0"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$RAW_B2P = "https://raw.githubusercontent.com/b2p-pw/b2p/main/win"
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
            iex "& { `$OriginUrl='$url'; $(Invoke-RestMethod -Uri $url) } -v latest"
            Read-Host "`nProcess finished. Press Enter..."
        }
    } catch { Write-Host "Connection error." -ForegroundColor Red; Pause }
}

function Manage-Installed {
    Show-Header
    if (-not (Test-Path $B2P_APPS)) { Write-Host "Nenhum app instalado." -ForegroundColor Yellow; Pause; return }
    $installedApps = @(Get-ChildItem $B2P_APPS -Directory)
    if ($installedApps.Count -eq 0) { Write-Host "Nenhum app instalado." -ForegroundColor Yellow; Pause; return }
    
    Write-Host "`nAplicativos Instalados:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $installedApps.Count; $i++) { " [{0,2}] {1}" -f ($i + 1), $installedApps[$i].Name }
    Write-Host " [ Q] Voltar" -ForegroundColor Yellow

    $choice = Read-Host "`nSelecione um app"
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $installedApps.Count) {
        $app = $installedApps[$idx - 1].Name
        $versions = @(Get-ChildItem (Join-Path $B2P_APPS $app) -Directory | Select-Object -ExpandProperty Name)
        
        Show-Header
        Write-Host "Gerenciando: $app" -ForegroundColor Cyan
        Write-Host "Versões: $($versions -join ', ')" -ForegroundColor Gray
        Write-Host "`n [1] Upgrade" -Write-Host " [2] Set Default Version" -Write-Host " [3] Create Custom Shim"
        Write-Host " [4] Set System PATH" -Write-Host " [5] Unset System PATH" -Write-Host " [6] Uninstall"
        Write-Host " [Q] Voltar"

        switch (Read-Host "`nOpção") {
            "1" { iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$app/up.s") }" }
            "2" {
                $verIn = Read-Host "Versão desejada"
                $verReal = Resolve-B2PVersion -App $app -Ver $verIn
                $source = Join-Path $B2P_TELEPORTS "$app-v$verReal.bat"
                if (-not (Test-Path $source)) { $source = Join-Path $B2P_TELEPORTS "$app-latest.bat" }
                if (Test-Path $source) { Copy-Item $source (Join-Path $B2P_TELEPORTS "$app.bat") -Force; Write-Host "Padrão atualizado!" -ForegroundColor Green }
            }
            "6" { 
                $ver = Read-Host "Versão ou 'all'"
                $verReal = Resolve-B2PVersion -App $app -Ver $ver
                $localUn = Join-Path $B2P_APPS "$app\$verReal\uninstall.ps1"
                if (Test-Path $localUn) {
                    $tempUn = Join-Path $env:TEMP "b2p-un-$app.ps1"; Copy-Item $localUn $tempUn -Force
                    powershell -NoProfile -ExecutionPolicy Bypass -File $tempUn -Name $app -Version $ver
                    Remove-Item $tempUn -ErrorAction SilentlyContinue
                } else { iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$app/un.s") } -Name '$app' -Version '$ver'" }
            }
            # ... (Demais opções implementam a mesma lógica de Resolve-B2PVersion)
        }
        Read-Host "`nConcluído. Enter..."
    }
}

# --- ROTEAMENTO CLI ---
if ($install) { 
    if ($install -eq "b2p") { Setup-B2P-Self } 
    else { 
        $sf = if ($s) { "-s" } else { "" }
        $url = "$RAW_W/$install/i.s"
        iex "& { `$OriginUrl='$url'; $(Invoke-RestMethod -Uri $url) } -v '$v' $sf"
    }
    return 
}

if ($uninstall) {
    $verReal = Resolve-B2PVersion -App $uninstall -Ver $v
    $localUn = Join-Path $B2P_APPS "$uninstall\$verReal\uninstall.ps1"
    if (Test-Path $localUn) {
        $tempUn = Join-Path $env:TEMP "b2p-un-$uninstall.ps1"; Copy-Item $localUn $tempUn -Force
        powershell -NoProfile -ExecutionPolicy Bypass -File $tempUn -Name $uninstall -Version $v
        Remove-Item $tempUn -ErrorAction SilentlyContinue
    } else { iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$uninstall/un.s") } -Name '$uninstall' -Version '$v'" }
    return
}

if ($upgrade) { iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$upgrade/up.s") } $(if($s){'-s'})"; return }

# --- MENU PRINCIPAL ---
while ($true) {
    Show-Header
    Write-Host " [1] Explorar Apps" -Write-Host " [2] Pesquisar App" -Write-Host " [3] Gerenciar Instalados" -Write-Host " [4] Sistema (Doctor/Update)" -Write-Host " [0] Sair"
    switch (Read-Host "`nEscolha") {
        "1" { Show-Catalog }
        "2" { $q = Read-Host "Busca"; Show-Catalog -filter $q }
        "3" { Manage-Installed }
        "4" { Show-System-Tools }
        "0" { exit }
    }
}