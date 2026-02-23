# core.ps1 - v1.3.5
$B2P_CORE_VERSION = "1.3.5"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$B2P_HOME = Join-Path $env:USERPROFILE ".b2p"
$B2P_APPS = Join-Path $B2P_HOME "apps"
$B2P_TELEPORTS = Join-Path $B2P_HOME "teleports"
$B2P_SHIMS = Join-Path $B2P_HOME "shims"
$B2P_BIN = Join-Path $B2P_HOME "bin"

@($B2P_APPS, $B2P_TELEPORTS, $B2P_SHIMS, $B2P_BIN) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null }
}

function Install-B2PApp {
    param ([Object]$Manifest, [String]$Version, [Switch]$Silent, [ScriptBlock]$PreInstall, [ScriptBlock]$PostInstall)

    $AppName = $Manifest.Name.ToLower()
    $AppBaseDir = Join-Path $B2P_APPS $AppName
    $InstallDir = Join-Path $AppBaseDir $Version
    
    if ($PreInstall) { & $PreInstall }

    # Download e Extração
    $urlExt = [System.IO.Path]::GetExtension($Manifest.Url)
    if ([string]::IsNullOrWhiteSpace($urlExt) -or $urlExt -eq ".tmp") { $urlExt = ".zip" }
    $tempFile = Join-Path $env:TEMP "$([guid]::NewGuid().ToString())$urlExt"
    
    if (-not $Silent) {
        Write-Host "`n[b2p] Baixando $($Manifest.Name) $Version..." -ForegroundColor Cyan
        Start-BitsTransfer -Source $Manifest.Url -Destination $tempFile -Priority Foreground
    } else { Invoke-WebRequest -Uri $Manifest.Url -OutFile $tempFile }

    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    New-Item $InstallDir -ItemType Directory -Force | Out-Null
    
    Write-Host ">>> Extraindo arquivos..." -ForegroundColor Gray
    Expand-Archive -Path $tempFile -DestinationPath $InstallDir -Force
    Remove-Item $tempFile -ErrorAction SilentlyContinue

    # Limpeza de subpastas
    $sub = Get-ChildItem $InstallDir -Directory | Select-Object -First 1
    if ($sub -and $sub.Name -like "*$($Manifest.Name)*") {
        Get-ChildItem $sub.FullName | Move-Item -Destination $InstallDir -Force
        Remove-Item $sub.FullName -Recurse -Force
    }

    # Registro de Metadados Inicial
    $meta = @{ 
        Name = $Manifest.Name; 
        Version = $Version; 
        BinPath = Join-Path $InstallDir $Manifest.RelativeBinPath;
        CoreVersion = $B2P_CORE_VERSION;
        Exposures = @{ Teleports = @(); Shims = @() }
    }

    # Criar Teleportes
    $tList = Create-B2PTeleports -Name $Manifest.Name -Version $Version -BinPath $meta.BinPath
    $meta.Exposures.Teleports = $tList

    # Criar Shims do Manifesto
    if ($Manifest.Shims) {
        foreach ($s in $Manifest.Shims) {
            $binaryFull = Join-Path $meta.BinPath $s.bin
            $sList = Create-B2PShim -BinaryPath $binaryFull -Alias $s.alias -Version $Version -AppName $AppName
            $meta.Exposures.Shims += $sList
        }
    }

    # Salvar Metadados Finais
    $meta | ConvertTo-Json -Depth 5 | Out-File (Join-Path $InstallDir "b2p-metadata.json") -Encoding UTF8

    # Gerar Desinstalador Local Inteligente
    $unPath = Join-Path $InstallDir "uninstall.ps1"
    $unContent = @"
param([String]`$Name = '$AppName', [String]`$Version = '$Version')
`$B2P_HOME = Join-Path `$env:USERPROFILE '.b2p'
Set-Location (Join-Path `$B2P_HOME 'apps\$AppName')
if (Test-Path (Join-Path `$B2P_HOME 'bin\core.ps1')) { . (Join-Path `$B2P_HOME 'bin\core.ps1') } 
else { . ([ScriptBlock]::Create((Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/b2p-pw/b2p/main/win/core.ps1'))) }
Uninstall-B2PApp -Name `$Name -Version `$Version
"@
    $unContent | Out-File $unPath -Encoding UTF8

    if ($PostInstall) { & $PostInstall }
    Write-Host "[b2p] Instalado com sucesso!" -ForegroundColor Green
}

function Create-B2PTeleports {
    param($Name, $Version, $BinPath)
    $created = @()
    $files = @{
        "$Name-v$Version.bat" = $true
        "$Name-latest.bat"    = $true
        "$Name.bat"           = (-not (Test-Path (Join-Path $B2P_TELEPORTS "$Name.bat"))) # Imutável: só cria se não existir
    }

    $content = "@echo off`nchcp 65001 > nul`nset B2P_BIN=$BinPath`nif `"%~1`"==`"`" (echo $Name v$Version) else ( `"%B2P_BIN%\%~1`" %~2 %~3 %~4 %~5 %~6 )"
    
    foreach ($f in $files.Keys) {
        if ($files[$f]) {
            $path = Join-Path $B2P_TELEPORTS $f
            $content | Out-File $path -Encoding UTF8
            $created += $path
        }
    }
    return $created
}

function Create-B2PShim {
    param($BinaryPath, $Alias, $Version, $AppName)
    $created = @()
    # Nome da versão e nome limpo
    $vAlias = "$Alias-v$Version.bat"
    $cleanAlias = "$Alias.bat"

    $content = "@echo off`nchcp 65001 > nul`n`"$BinaryPath`" %*"
    
    # 1. Sempre cria o versionado
    $vPath = Join-Path $B2P_SHIMS $vAlias
    $content | Out-File $vPath -Encoding UTF8
    $created += $vPath

    # 2. Cria o limpo apenas se não existir (Imutabilidade)
    $cPath = Join-Path $B2P_SHIMS $cleanAlias
    if (-not (Test-Path $cPath)) {
        $content | Out-File $cPath -Encoding UTF8
        $created += $cPath
    }
    
    return $created
}

function Uninstall-B2PApp {
    param($Name, $Version)
    $AppName = $Name.ToLower()
    $AppRoot = Join-Path $B2P_APPS $AppName
    
    # Sai da pasta da versão para evitar Lock, mas fica na pasta do App
    if (Test-Path $AppRoot) { Set-Location $AppRoot } else { Set-Location $env:USERPROFILE }

    Write-Host "[b2p] Removendo $Name ($Version)..." -ForegroundColor Yellow

    # 1. Ler metadados para saber o que esta versão "é dona"
    $versionsToRemove = if ($Version -eq "all") { Get-ChildItem $AppRoot -Directory | Select-Object -ExpandProperty Name } else { @($Version) }

    foreach ($v in $versionsToRemove) {
        $metaFile = Join-Path $AppRoot "$v\b2p-metadata.json"
        if (Test-Path $metaFile) {
            $meta = Get-Content $metaFile | ConvertFrom-Json
            # Deletar Teleports e Shims que esta versão registrou
            foreach ($file in $meta.Exposures.Teleports) { if (Test-Path $file) { Remove-Item $file -Force } }
            foreach ($file in $meta.Exposures.Shims) { if (Test-Path $file) { Remove-Item $file -Force } }
        }
    }

    # 2. Limpeza genérica de teleports persistentes se for 'all'
    if ($Version -eq "all") {
        Get-ChildItem $B2P_TELEPORTS -Filter "$AppName*" | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem $B2P_SHIMS -Filter "*.bat" | ForEach-Object {
            if ((Get-Content $_.FullName -ErrorAction SilentlyContinue) -like "*\apps\$AppName\*") { Remove-Item $_.FullName -Force }
        }
    }

    # 3. Limpar PATH Real
    $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $newPath = ($uPath.Split(';') | Where-Object { $_ -notlike "*\.b2p\apps\$AppName\*" }) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

    # 4. Deletar pastas físicas
    if ($Version -eq "all") {
        Set-Location $B2P_APPS
        if (Test-Path $AppRoot) { Remove-Item $AppRoot -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        $VerPath = Join-Path $AppRoot $Version
        if (Test-Path $VerPath) { Remove-Item $VerPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path (Join-Path $AppRoot $Version)) {
        Write-Host "AVISO: Alguns arquivos não puderam ser removidos. Eles sumirão ao fechar o terminal." -ForegroundColor Yellow
    } else {
        Write-Host "[b2p] Remoção concluída!" -ForegroundColor Green
    }
}