# b2p.ps1 - O Gerenciador Definitivo (CLI & Interativo)
param(
    [String]$install,
    [String]$uninstall,
    [String]$upgrade,
    [String]$default,
    [String]$search,
    [String]$v = "latest",
    [Switch]$s = $false
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RAW_B2P = "https://raw.githubusercontent.com/b2p-pw/b2p/main/win"
$RAW_W   = "https://raw.githubusercontent.com/b2p-pw/w/main"
$API_W   = "https://api.github.com/repos/b2p-pw/w/contents"

$B2P_HOME = Join-Path $env:USERPROFILE ".b2p"
$localCore = Join-Path $B2P_HOME "bin\core.ps1"
if (Test-Path $localCore) { . $localCore }
else { . ([ScriptBlock]::Create((irm "$RAW_B2P/core.ps1"))) }

function Resolve-B2PVersion {
    param($App, $Ver)
    if ($Ver -eq "latest") {
        $appPath = Join-Path $B2P_APPS $App
        if (Test-Path $appPath) {
            return (Get-ChildItem $appPath -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name
        }
    }
    return $Ver
}

# Garantia de variáveis globais
if (-not $B2P_BIN) {
    $B2P_BIN = Join-Path $B2P_HOME "bin"; $B2P_SHIMS = Join-Path $B2P_HOME "shims"
    $B2P_APPS = Join-Path $B2P_HOME "apps"; $B2P_TELEPORTS = Join-Path $B2P_HOME "teleports"
    $B2P_CACHE = Join-Path $B2P_HOME "installer-cache"
}

function Show-Header {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "    Binary-2-Path (b2p) CLI v$B2P_CLI_VERSION  " -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Magenta
}

# --- SEÇÃO 1: CATÁLOGO E BUSCA ---
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
        if ($choice -eq "Q" -or [string]::IsNullOrWhiteSpace($choice)) { return }
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $apps.Count) {
            $selected = $apps[$idx - 1]
            iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$selected/i.s") } -v latest"
            Read-Host "`nPressione Enter para continuar..."
        }
    } catch { Write-Host "Erro de conexão com o catálogo." -ForegroundColor Red; Pause }
}

# --- SEÇÃO 2: GESTÃO DE APPS INSTALADOS ---
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
        Write-Host "Versões no disco: $($versions -join ', ')" -ForegroundColor Gray
        Write-Host "`n [1] Upgrade (latest)"
        Write-Host " [2] Set Default (Mudar app.bat)"
        Write-Host " [3] Create Custom Shim (Atalho)"
        Write-Host " [4] Set Real PATH (Injetar)"
        Write-Host " [5] Unset Real PATH (Remover)"
        Write-Host " [6] Uninstall"
        Write-Host " [Q] Voltar"

        switch (Read-Host "`nOpção") {
            "1" { iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$app/up.s") }" }
            "2" {
                $ver = Read-Host "Versão desejada (ex: v20251216)"
                if (-not $ver.StartsWith("v") -and $ver -ne "latest") { $ver = "v$ver" }
                $source = Join-Path $B2P_TELEPORTS "$app-$ver.bat"
                if (Test-Path $source) { Copy-Item $source (Join-Path $B2P_TELEPORTS "$app.bat") -Force; Write-Host "Padrão alterado!" -ForegroundColor Green }
                else { Write-Host "Versão não encontrada." -ForegroundColor Red }
            }
            "3" {
                $alias = Read-Host "Nome do comando (ex: clang)"; $exe = Read-Host "Executável (ex: clang.exe)"
                $ver = Read-Host "Versão (padrão: latest)"; if ([string]::IsNullOrWhiteSpace($ver)) { $ver = "latest" }
                $metaFile = Join-Path $B2P_APPS "$app\$ver\b2p-metadata.json"
                if (Test-Path $metaFile) {
                    $meta = Get-Content $metaFile | ConvertFrom-Json
                    Create-B2PShim -BinaryPath (Join-Path $meta.BinPath $exe) -Alias $alias
                }
            }
            "4" {
                $verInput = Read-Host "Versão (padrão: latest)"
                if ([string]::IsNullOrWhiteSpace($verInput)) { $verInput = "latest" }
                $verReal = Resolve-B2PVersion -App $app -Ver $verInput
                $metaPath = Join-Path $B2P_APPS "$app\$verReal\b2p-metadata.json"
                if (Test-Path $metaPath) {
                    $meta = Get-Content $metaPath | ConvertFrom-Json
                    $binToInject = $meta.BinPath
                    $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
                    if ($uPath.Split(';') -notcontains $binToInject) {
                        Write-Host "Injetando no PATH Real: $binToInject" -ForegroundColor Cyan
                        $cleanPath = $uPath.TrimEnd(';')
                        $newPath = "$cleanPath;$binToInject"
                        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
                        Write-Host "Sucesso! O PATH foi atualizado." -ForegroundColor Green
                    } else {
                        Write-Host "O caminho já está presente no PATH Real." -ForegroundColor Yellow
                    }
                } else { 
                    Write-Host "Erro: Versão '$verReal' não encontrada em $B2P_APPS\$app" -ForegroundColor Red 
                }
            }
            "5" {
                $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
                $pathArray = $uPath.Split(';') | Where-Object { $_ -notlike "*\.b2p\apps\$app\*" }
                [Environment]::SetEnvironmentVariable("Path", ($pathArray -join ';'), "User")
            }
            # Dentro do b2p.ps1, opção "6" do menu Manage-Installed:
            "6" { 
                $ver = Read-Host "Versão específica ou 'all'"
                # Busca local
                $localUn = Join-Path $B2P_APPS "$app\latest\uninstall.ps1"
                if (-not (Test-Path $localUn)) { $localUn = Join-Path $B2P_APPS "$app\$v\uninstall.ps1" }

                if (Test-Path $localUn) {
                    # Executa o script local passando os parâmetros
                    powershell -NoProfile -ExecutionPolicy Bypass -File $localUn -Name $app -Version $ver
                } else {
                    # Chamada Web corrigida: O param deve vir primeiro, então injetamos os argumentos no final da string iex
                    $unUrl = "https://raw.githubusercontent.com/b2p-pw/w/main/$app/un.s"
                    iex "& { $(Invoke-RestMethod -Uri $unUrl) } -Name '$app' -Version '$ver'"
                }
            }
        }
        Read-Host "`nProcesso concluído. Enter..."
    }
}

# --- SEÇÃO 3: FERRAMENTAS DO SISTEMA B2P ---
function Show-System-Tools {
    while ($true) {
        Show-Header
        Write-Host "--- Ferramentas do Sistema B2P ---" -ForegroundColor Cyan
        Write-Host " [1] B2P Doctor (Verificar Saúde do PATH/Shims)"
        Write-Host " [2] Self-Update B2P Manager (Atualizar Core/CLI)"
        Write-Host " [3] Reparar/Reinstalar B2P (Forçar Shim Mestre)"
        Write-Host " [4] Limpar Cache de Instaladores (.tmp)"
        Write-Host " [Q] Voltar"
        
        switch (Read-Host "`nOpção") {
            "1" {
                Write-Host "`n[Doctor] Verificando integridade..." -ForegroundColor Gray
                $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
                $missing = @()
                if ($uPath -notlike "*\.b2p\shims*") { $missing += "Shims" }
                if ($uPath -notlike "*\.b2p\teleports*") { $missing += "Teleports" }
                if ($missing.Count -gt 0) { Write-Host "Atenção: Pastas $($missing -join ' e ') não estão no PATH!" -ForegroundColor Red }
                else { Write-Host "Saúde do PATH: OK" -ForegroundColor Green }
                Write-Host "`n[Doctor] Relatório de Versões:" -ForegroundColor Cyan
                Write-Host " - b2p CLI:    $B2P_CLI_VERSION"
                Write-Host " - b2p Core:   $B2P_CORE_VERSION"
                Write-Host " - PowerShell: $($PSVersionTable.PSVersion)"
                Pause
            }
            "2" {
                Write-Host "`n[Update] Buscando novas versões do b2p..." -ForegroundColor Cyan
                Invoke-WebRequest "$RAW_B2P/core.ps1" -OutFile (Join-Path $B2P_BIN "core.ps1")
                Invoke-WebRequest "$RAW_B2P/b2p.ps1" -OutFile (Join-Path $B2P_BIN "b2p.ps1")
                Write-Host "Gerenciador atualizado!" -ForegroundColor Green; Pause
            }
            "3" { Setup-B2P-Self }
            "4" {
                $tempFiles = Get-ChildItem "$env:TEMP" -Filter "*.tmp" | Where-Object { $_.Length -gt 1MB }
                $tempFiles | Remove-Item -Force -ErrorAction SilentlyContinue
                Write-Host "Cache limpo." -ForegroundColor Green; Pause
            }
            "Q" { return }
        }
    }
}

function Setup-B2P-Self {
    Show-Header
    Write-Host "Configurando b2p CLI..." -ForegroundColor Cyan
    @($B2P_BIN, $B2P_SHIMS, $B2P_TELEPORTS, $B2P_APPS) | ForEach-Object { if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null } }
    $b2pBat = Join-Path $B2P_SHIMS "b2p.bat"
    if (Test-Path $b2pBat) { Set-ItemProperty $b2pBat -Name IsReadOnly -Value $false }
    Invoke-WebRequest "$RAW_B2P/core.ps1" -OutFile (Join-Path $B2P_BIN "core.ps1")
    Invoke-WebRequest "$RAW_B2P/b2p.ps1" -OutFile (Join-Path $B2P_BIN "b2p.ps1")
    $b2pBat = Join-Path $B2P_SHIMS "b2p.bat"
    if (Test-Path $b2pBat) { Set-ItemProperty $b2pBat -Name IsReadOnly -Value $false }

    # Conteúdo com CHCP para o b2p.bat
    $content = "@echo off`nchcp 65001 > nul`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$B2P_BIN\b2p.ps1`" %*"
    
    # Salva em UTF8
    $content | Out-File $b2pBat -Encoding UTF8
    Set-ItemProperty $b2pBat -Name IsReadOnly -Value $true
    
    $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pSplit = $uPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    $modified = $false
    foreach($p in @($B2P_SHIMS, $B2P_TELEPORTS)) { if ($pSplit -notcontains $p) { $uPath = "$uPath;$p"; $modified = $true } }
    if ($modified) { [Environment]::SetEnvironmentVariable("Path", $uPath, "User") }
    Write-Host "Finalizado! Reinicie o terminal." -ForegroundColor Green; Pause
}

# --- ROTEAMENTO CLI ---
if ($install) { 
    if ($install -eq "b2p") { Setup-B2P-Self } 
    else { 
        # Correção do Switch para string e verificação de URL
        $silentFlag = if ($s) { "-s" } else { "" }
        $url = "$RAW_W/$install/i.s"
        Write-Host "Invocando: $url" -ForegroundColor Gray
        iex "& { $(Invoke-RestMethod -Uri $url) } -v '$v' $silentFlag" 
    }
    return 
}

if ($uninstall) { 
    # Tenta rodar o desinstalador local da versão específica
    $localUn = Join-Path $B2P_APPS "$uninstall\$v\uninstall.ps1"
    if (Test-Path $localUn) {
        & $localUn -v $v
    } else {
        # Fallback para Web
        iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$uninstall/un.s") } -v $v"
    }
    return 
}

if ($upgrade) {
    iex "& { $(Invoke-RestMethod -Uri "$RAW_W/$upgrade/up.s") }"
    return
}

if ($default) { 
    $source = Join-Path $B2P_TELEPORTS "$install-$default.bat"
    if (Test-Path $source) { Copy-Item $source (Join-Path $B2P_TELEPORTS "$install.bat") -Force }
    return
}

# --- MENU PRINCIPAL ---
while ($true) {
    Show-Header
    Write-Host " [1] Explorar/Instalar Apps"
    Write-Host " [2] Pesquisar no Catálogo"
    Write-Host " [3] Gerenciar Aplicativos Instalados"
    Write-Host " [4] Ferramentas do Sistema (Doctor/Update)"
    Write-Host " [0] Sair"
    switch (Read-Host "`nEscolha") {
        "1" { Show-Catalog }
        "2" { $q = Read-Host "Busca"; Show-Catalog -filter $q }
        "3" { Manage-Installed }
        "4" { Show-System-Tools }
        "0" { exit }
    }
}