# core.ps1 - v1.4.0
$B2P_CORE_VERSION = "1.4.0"
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
    
    if (Test-Path $InstallDir) {
        Write-Host "[b2p] Slot '$Version' detectado. Rodando desinstalador local antes de atualizar..." -ForegroundColor Gray
        Uninstall-B2PApp -Name $Manifest.Name -Version $Version
    }

    if ($PreInstall) { & $PreInstall }

    # Download
    $urlExt = [System.IO.Path]::GetExtension($Manifest.Url)
    if ([string]::IsNullOrWhiteSpace($urlExt) -or $urlExt -eq ".tmp") { $urlExt = ".zip" }
    $tempFile = Join-Path $env:TEMP "$([guid]::NewGuid().ToString())$urlExt"
    
    if (-not $Silent) {
        Write-Host "`n[b2p] Baixando $($Manifest.Name) ($Version)..." -ForegroundColor Cyan
        Start-BitsTransfer -Source $Manifest.Url -Destination $tempFile -Priority Foreground
    } else { Invoke-WebRequest -Uri $Manifest.Url -OutFile $tempFile }

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

    # Metadados Iniciais
    $meta = @{ 
        Name = $Manifest.Name; 
        DisplayVersion = $Version; 
        RealVersion = $Manifest.Version; 
        BinPath = Join-Path $InstallDir $Manifest.RelativeBinPath;
        CoreVersion = $B2P_CORE_VERSION;
        InstallDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss");
        Exposures = @{ Teleports = @(); Shims = @() }
    }

    # Criar Teleportes e Shims
    $meta.Exposures.Teleports = Create-B2PTeleports -Name $Manifest.Name -Version $Version -BinPath $meta.BinPath
    if ($Manifest.Shims) {
        foreach ($s in $Manifest.Shims) {
            $sList = Create-B2PShim -BinaryPath (Join-Path $meta.BinPath $s.bin) -Alias $s.alias -Version $Version -AppName $AppName
            $meta.Exposures.Shims += $sList
        }
    }

    # Salva Metadados ANTES de baixar o uninstaller para que ele possa ler
    $meta | ConvertTo-Json -Depth 5 | Out-File (Join-Path $InstallDir "b2p-metadata.json") -Encoding UTF8

    # BAIXAR UNINSTALLER REAL DO SERVIDOR (Copia a lógica atual do repo para o local)
    Write-Host ">>> Sincronizando desinstalador (uninstall.ps1)..." -ForegroundColor Gray
    $unUrl = "https://raw.githubusercontent.com/b2p-pw/windows-catalog/main/$AppName/uninstall.ps1"
    try {
        Invoke-WebRequest -Uri $unUrl -OutFile (Join-Path $InstallDir "uninstall.ps1") -ErrorAction Stop
    } catch {
        # Fallback caso o arquivo não exista no servidor
        "@'param([String]`$Name='$AppName', [String]`$Version='$Version'); . (Join-Path `$env:USERPROFILE '.b2p\bin\core.ps1'); Uninstall-B2PApp -Name `$Name -Version `$Version '@" | Out-File (Join-Path $InstallDir "uninstall.ps1")
    }

    if ($PostInstall) { & $PostInstall }
    Write-Host "[b2p] Pronto! $($Manifest.Name) instalado." -ForegroundColor Green
}

function Create-B2PTeleports {
    param($Name, $Version, $BinPath)
    $created = @()
    $teleName = if ($Version -eq "latest") { "$Name-latest.bat" } else { "$Name-v$Version.bat" }
    $files = @{ $teleName = $true }
    if (-not (Test-Path (Join-Path $B2P_TELEPORTS "$Name.bat"))) { $files["$Name.bat"] = $true }

    $content = "@echo off`nchcp 65001 > nul`nset B2P_BIN=$BinPath`nif `"%~1`"==`"`" (echo $Name $Version) else ( `"%B2P_BIN%\%~1`" %~2 %~3 %~4 %~5 %~6 )"
    foreach ($f in $files.Keys) {
        $path = Join-Path $B2P_TELEPORTS $f
        $content | Out-File $path -Encoding UTF8
        $created += $path
    }
    return $created
}

function Create-B2PShim {
    param($BinaryPath, $Alias, $Version, $AppName)
    $created = @()
    $shimName = if ($Version -eq "latest") { "$Alias.bat" } else { "$Alias-v$Version.bat" }
    $path = Join-Path $B2P_SHIMS $shimName
    $content = "@echo off`nchcp 65001 > nul`n`"$BinaryPath`" %*"
    $content | Out-File $path -Encoding UTF8
    $created += $path
    return $created
}

function Uninstall-B2PApp {
    param($Name, $Version)
    $AppName = $Name.ToLower()
    $AppRoot = Join-Path $B2P_APPS $AppName
    
    if (Test-Path $AppRoot) { Set-Location $AppRoot }

    Write-Host "[b2p] Removendo $Name ($Version)..." -ForegroundColor Yellow

    $versionsToRemove = if ($Version -eq "all") { 
        if (Test-Path $AppRoot) { Get-ChildItem $AppRoot -Directory | Select-Object -ExpandProperty Name } 
    } else { @($Version) }

    foreach ($v in $versionsToRemove) {
        $metaFile = Join-Path $AppRoot "$v\b2p-metadata.json"
        if (Test-Path $metaFile) {
            $meta = Get-Content $metaFile | ConvertFrom-Json
            # Remove exatamente o que foi registrado nos metadados
            foreach ($file in $meta.Exposures.Teleports) { if (Test-Path $file) { Remove-Item $file -Force } }
            foreach ($file in $meta.Exposures.Shims) { if (Test-Path $file) { Remove-Item $file -Force } }
        }
        $targetDir = Join-Path $AppRoot $v
        if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($Version -eq "all") {
        Set-Location $B2P_APPS
        if (Test-Path $AppRoot) { Remove-Item $AppRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "[b2p] Remoção concluída." -ForegroundColor Green
}