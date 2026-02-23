# b2p.ps1 - v1.4.9
param([String]$install, [String]$uninstall, [String]$upgrade, [String]$default, [String]$search, [String]$v = "latest", [Switch]$s = $false)

$B2P_CLI_VERSION = "1.4.9"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RAW_B2P = "https://raw.githubusercontent.com/b2p-pw/b2p/main/win"
$RAW_W   = "https://raw.githubusercontent.com/b2p-pw/windows-catalog/main"

$B2P_HOME = Join-Path $env:USERPROFILE ".b2p"
$B2P_APPS = Join-Path $B2P_HOME "apps"

# Função para achar o uninstall.ps1 local
function Get-LocalUninstaller {
    param($App, $Ver)
    $verReal = Resolve-B2PVersion -App $App -Ver $Ver
    $path = Join-Path $B2P_APPS "$App\$verReal\uninstall.ps1"
    if (Test-Path $path) { return $path }
    return $null
}

$localCore = Join-Path $B2P_HOME "bin\core.ps1"
if (Test-Path $localCore) { . $localCore } else { . ([ScriptBlock]::Create((irm "$RAW_B2P/core.ps1"))) }

if (-not $B2P_BIN) {
    $B2P_BIN = Join-Path $B2P_HOME "bin"; $B2P_SHIMS = Join-Path $B2P_HOME "shims"
    $B2P_APPS = Join-Path $B2P_HOME "apps"; $B2P_TELEPORTS = Join-Path $B2P_HOME "teleports"
}

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

function Show-Catalog {
    param([String]$filter = "")
    Show-Header
    Write-Host "Buscando catálogo no repositório W..." -ForegroundColor Gray
    try {
        $items = Invoke-RestMethod -Uri $API_W -UserAgent "b2p"
        $apps = @($items | Where-Object { $_.type -eq "dir" -and $_.name -like "*$filter*" } | Select-Object -ExpandProperty name)
        if ($apps.Count -eq 0) { Write-Host "Nenhum app encontrado." -ForegroundColor Yellow }
        else {
            Write-Host "`nDisponíveis para instalação:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $apps.Count; $i++) { " [{0,2}] {1}" -f ($i + 1), $apps[$i] }
        }
        Write-Host " [ Q] Voltar" -ForegroundColor Yellow
        $choice = Read-Host "`nSelecione"
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $apps.Count) {
            $selected = $apps[$idx - 1]
            iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$selected/i.s") } -v latest"
            Read-Host "`nPressione Enter para continuar..."
        }
    } catch { Write-Host "Erro de conexão." -ForegroundColor Red; Pause }
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
        Write-Host "`n [1] Upgrade"
        Write-Host " [2] Set Default Version"
        Write-Host " [3] Create Custom Shim"
        Write-Host " [4] Set System PATH"
        Write-Host " [5] Unset System PATH"
        Write-Host " [6] Uninstall"
        Write-Host " [Q] Voltar"

        switch (Read-Host "`nOpção") {
            "1" { iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$app/up.s") }" }
            "2" {
                $verIn = Read-Host "Versão desejada"
                $source = Join-Path $B2P_TELEPORTS "$app-v$verIn.bat"
                if (Test-Path $source) { Copy-Item $source (Join-Path $B2P_TELEPORTS "$app.bat") -Force; Write-Host "Sucesso!" -ForegroundColor Green }
            }
            "3" {
                $alias = Read-Host "Nome do comando"; $exe = Read-Host "Executável (bin\...)"; $verIn = Read-Host "Versão (padrão: latest)"
                $verReal = Resolve-B2PVersion -App $app -Ver (if($verIn){$verIn}else{"latest"})
                $meta = Get-Content (Join-Path $B2P_APPS "$app\$verReal\b2p-metadata.json") | ConvertFrom-Json
                Create-B2PShim -BinaryPath (Join-Path $meta.BinPath (Split-Path $exe -Leaf)) -Alias $alias -Version $verReal -AppName $app
            }
            "4" {
                $verIn = Read-Host "Versão (padrão: latest)"
                $verReal = Resolve-B2PVersion -App $app -Ver (if($verIn){$verIn}else{"latest"})
                $meta = Get-Content (Join-Path $B2P_APPS "$app\$verReal\b2p-metadata.json") | ConvertFrom-Json
                $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($uPath.Split(';') -notcontains $meta.BinPath) { [Environment]::SetEnvironmentVariable("Path", "$($uPath.TrimEnd(';'));$($meta.BinPath)", "User") }
            }
            "5" {
                $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
                $newPath = ($uPath.Split(';') | Where-Object { $_ -notlike "*\.b2p\apps\$app\*" }) -join ';'
                [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
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
        }
        Read-Host "`nProcesso concluído. Enter..."
    }
}

function Show-System-Tools {
    while ($true) {
        Show-Header
        Write-Host " [1] B2P Doctor" -Write-Host " [2] Self-Update" -Write-Host " [3] Reparar CLI" -Write-Host " [Q] Voltar"
        switch (Read-Host "`nOpção") {
            "1" { Write-Host "CLI: $B2P_CLI_VERSION | Core: $B2P_CORE_VERSION"; Pause }
            "2" {
                Invoke-WebRequest "$RAW_B2P/core.ps1" -OutFile (Join-Path $B2P_BIN "core.ps1")
                Invoke-WebRequest "$RAW_B2P/b2p.ps1" -OutFile (Join-Path $B2P_BIN "b2p.ps1")
                Write-Host "Atualizado!" -ForegroundColor Green; Pause
            }
            "3" { Setup-B2P-Self }
            "Q" { return }
        }
    }
}

function Setup-B2P-Self {
    Show-Header
    Write-Host "Configurando B2P CLI..." -ForegroundColor Cyan
    @($B2P_BIN, $B2P_SHIMS, $B2P_TELEPORTS, $B2P_APPS) | ForEach-Object { if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null } }
    $b2pBat = Join-Path $B2P_SHIMS "b2p.bat"
    if (Test-Path $b2pBat) { Set-ItemProperty $b2pBat -Name IsReadOnly -Value $false }
    Invoke-WebRequest "$RAW_B2P/core.ps1" -OutFile (Join-Path $B2P_BIN "core.ps1")
    Invoke-WebRequest "$RAW_B2P/b2p.ps1" -OutFile (Join-Path $B2P_BIN "b2p.ps1")
    $content = "@echo off`nchcp 65001 > nul`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$B2P_BIN\b2p.ps1`" %*"
    $content | Out-File $b2pBat -Encoding UTF8
    Set-ItemProperty $b2pBat -Name IsReadOnly -Value $true
    $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pSplit = $uPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    $modified = $false
    foreach($p in @($B2P_SHIMS, $B2P_TELEPORTS)) { if ($pSplit -notcontains $p) { $uPath = "$uPath;$p"; $modified = $true } }
    if ($modified) { [Environment]::SetEnvironmentVariable("Path", $uPath, "User") }
    Write-Host "Finalizado!" -ForegroundColor Green; Pause
}

# ROTEAMENTO
if ($install) { 
    if ($install -eq "b2p") { Setup-B2P-Self } 
    else { iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$install/i.s") } -v '$v' $(if($s){'-s'})" }
    return 
}
if ($uninstall) {
    $localScript = Get-LocalUninstaller -App $uninstall -Ver $v
    if ($localScript) {
        Write-Host "[b2p] Usando desinstalador local..." -ForegroundColor Gray
        # Executa via powershell file para evitar locks
        $tempExec = Join-Path $env:TEMP "b2p-un-task.ps1"
        Copy-Item $localScript $tempExec -Force
        powershell -NoProfile -ExecutionPolicy Bypass -File $tempExec -Name $uninstall -Version $v
        Remove-Item $tempExec -ErrorAction SilentlyContinue
    } else {
        Write-Host "[b2p] Desinstalador local não encontrado. Usando Remote Shim..." -ForegroundColor Yellow
        iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$uninstall/un.s") } -Name '$uninstall' -Version '$v'"
    }
    return
}
if ($upgrade) { iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$upgrade/up.s") } $(if($s){'-s'})"; return }

while ($true) {
    Show-Header
    Write-Host " [1] Explorar Apps" -Write-Host " [2] Pesquisar App" -Write-Host " [3] Gerenciar Instalados" -Write-Host " [4] Sistema" -Write-Host " [0] Sair"
    switch (Read-Host "`nEscolha") {
        "1" { Show-Catalog }
        "2" { $q = Read-Host "Busca"; Show-Catalog -filter $q }
        "3" { Manage-Installed }
        "4" { Show-System-Tools }
        "0" { exit }
    }
}