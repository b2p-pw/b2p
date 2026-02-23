# core.ps1 - v1.3.1
$B2P_CORE_VERSION = "1.3.1"
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

    $sub = Get-ChildItem $InstallDir -Directory | Select-Object -First 1
    if ($sub -and $sub.Name -like "*$($Manifest.Name)*") {
        Get-ChildItem $sub.FullName | Move-Item -Destination $InstallDir -Force
        Remove-Item $sub.FullName -Recurse -Force
    }

    $meta = @{ Name = $Manifest.Name; Version = $Version; BinPath = Join-Path $InstallDir $Manifest.RelativeBinPath; CoreVersion = $B2P_CORE_VERSION; InstallDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
    $meta | ConvertTo-Json | Out-File (Join-Path $InstallDir "b2p-metadata.json")

    $unPath = Join-Path $InstallDir "uninstall.ps1"
    $unContent = @"
param([String]`$Name = '$AppName', [String]`$Version = '$Version')
`$B2P_HOME = Join-Path `$env:USERPROFILE '.b2p'
`$coreLocal = Join-Path `$B2P_HOME 'bin\core.ps1'
Set-Location `$env:TEMP
if (Test-Path `$coreLocal) { . `$coreLocal } 
else { . ([ScriptBlock]::Create((Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/b2p-pw/b2p/main/win/core.ps1'))) }
Uninstall-B2PApp -Name `$Name -Version `$Version
"@
    $unContent | Out-File $unPath -Encoding UTF8

    Create-B2PTeleports -Name $Manifest.Name -Version $Version -BinPath $meta.BinPath
    if ($Manifest.Shims) {
        foreach ($s in $Manifest.Shims) {
            Create-B2PShim -BinaryPath (Join-Path $meta.BinPath $s.bin) -Alias $s.alias
        }
    }
    if ($PostInstall) { & $PostInstall }
    Write-Host "[b2p] Instalado com sucesso!" -ForegroundColor Green
}

function Create-B2PTeleports {
    param($Name, $Version, $BinPath)
    $vTele = Join-Path $B2P_TELEPORTS "$Name-v$Version.bat"
    $lTele = Join-Path $B2P_TELEPORTS "$Name-latest.bat"
    $dTele = Join-Path $B2P_TELEPORTS "$Name.bat"
    $content = "@echo off`nchcp 65001 > nul`nset B2P_BIN=$BinPath`nif `"%~1`"==`"`" (echo $Name v$Version) else ( `"%B2P_BIN%\%~1`" %~2 %~3 %~4 %~5 %~6 )"
    $content | Out-File $vTele -Encoding UTF8
    $content | Out-File $lTele -Encoding UTF8
    if (-not (Test-Path $dTele)) { $content | Out-File $dTele -Encoding UTF8 }
}

function Create-B2PShim {
    param($BinaryPath, $Alias)
    $shimPath = Join-Path $B2P_SHIMS "$Alias.bat"
    $content = "@echo off`nchcp 65001 > nul`n`"$BinaryPath`" %*"
    $content | Out-File $shimPath -Encoding UTF8
    Write-Host "[b2p] Shim criado: $Alias" -ForegroundColor Green
}

function Uninstall-B2PApp {
    param($Name, $Version)
    $AppName = $Name.ToLower()
    $AppRoot = Join-Path $B2P_APPS $AppName
    
    # Sai da pasta do app para evitar lock
    Set-Location $env:TEMP
    
    Write-Host "[b2p] Removendo $Name ($Version)..." -ForegroundColor Yellow

    Get-ChildItem $B2P_TELEPORTS -Filter "$AppName*" | Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path $B2P_SHIMS) {
        Get-ChildItem $B2P_SHIMS -Filter "*.bat" | ForEach-Object {
            $content = Get-Content $_.FullName -ErrorAction SilentlyContinue
            if ($content -like "*\apps\$AppName\*") { Remove-Item $_.FullName -Force }
        }
    }

    $uPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $newPath = ($uPath.Split(';') | Where-Object { $_ -notlike "*\.b2p\apps\$AppName\*" }) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

    if ($Version -eq "all") {
        if (Test-Path $AppRoot) { Remove-Item $AppRoot -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        $VerPath = Join-Path $AppRoot $Version
        if (Test-Path $VerPath) { Remove-Item $VerPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path (Join-Path $AppRoot $Version)) {
        Write-Host "AVISO: Alguns arquivos não puderam ser removidos agora. Tente fechar processos do app." -ForegroundColor Yellow
    } else {
        Write-Host "[b2p] Remoção concluída!" -ForegroundColor Green
    }
}