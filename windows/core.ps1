$B2P_CORE_VERSION = "1.4.1"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$B2P_HOME = Join-Path $env:USERPROFILE ".b2p"
$B2P_APPS = Join-Path $B2P_HOME "apps"
$B2P_TELEPORTS = Join-Path $B2P_HOME "teleports"
$B2P_SHIMS = Join-Path $B2P_HOME "shims"
$B2P_BIN = Join-Path $B2P_HOME "bin"

# Ensure basic infrastructure
@($B2P_APPS, $B2P_TELEPORTS, $B2P_SHIMS, $B2P_BIN) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null }
}

$B2P_AUDIT_LOG = Join-Path $B2P_HOME "audit.log"
$B2P_HASHES = Join-Path $B2P_HOME "hashes"

# --- SECURITY & HELPER FUNCTIONS ---
function Write-B2PAudit {
    param([String]$Message, [String]$Level = "INFO")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $B2P_AUDIT_LOG -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($Level -eq "ERROR") { Write-Host "[b2p:AUDIT] $entry" -ForegroundColor Red }
}

function Validate-B2PHash {
    param([String]$Url, [String]$Content)
    $hashFile = Join-Path $B2P_HASHES (([System.Uri]$Url).Segments[-1] + ".sha256")
    
    if (-not (Test-Path $B2P_HASHES)) { New-Item $B2P_HASHES -ItemType Directory -Force | Out-Null }
    
    $contentHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($Content))) -Algorithm SHA256).Hash
    
    if (Test-Path $hashFile) {
        $storedHash = Get-Content $hashFile
        if ($contentHash -ne $storedHash) {
            Write-B2PAudit "Hash mismatch for $Url. Potential tampering detected!" "ERROR"
            return $false
        }
    } else {
        # First time: store hash for future verification
        $contentHash | Set-Content $hashFile -Encoding UTF8
        Write-Host "[b2p] Hash stored for $Url (first run)" -ForegroundColor Gray
    }
    return $true
}

function Invoke-B2PRemoteScript {
    param([String]$Uri, [String]$ArgumentList = "")
    Write-B2PAudit "Executing remote script: $Uri"
    try {
        $script = Invoke-RestMethod -Uri $Uri -ErrorAction Stop
        if (-not (Validate-B2PHash -Url $Uri -Content $script)) {
            throw "Script validation failed"
        }
        iex "& { $script } $ArgumentList"
    } catch {
        Write-B2PAudit "Failed to execute remote script: $_" "ERROR"
        throw $_
    }
}

function Test-ValidFileName {
    param([String]$Name, [String]$Type = "filename")
    $invalidChars = '[<>:"/\\|?*]'
    if ($Name -match $invalidChars) {
        Write-Host "[b2p] Error: $Type contains invalid characters: $invalidChars" -ForegroundColor Red
        return $false
    }
    if ($Name.Length -gt 200) {
        Write-Host "[b2p] Error: $Type exceeds 200 characters" -ForegroundColor Red
        return $false
    }
    if ($Name -match '^\s+$') {
        Write-Host "[b2p] Error: $Type cannot be empty or whitespace" -ForegroundColor Red
        return $false
    }
    return $true
}

function Update-B2PPath {
    param([String]$Action, [String]$Scope = "User")
    $teleportPath = $B2P_TELEPORTS
    $shimPath = $B2P_SHIMS
    
    try {
        $envPath = [Environment]::GetEnvironmentVariable('PATH', $Scope)
        $pathArray = $envPath -split ';' | Where-Object { $_ -and $_.Trim() }
        
        $teleportExists = $pathArray -contains $teleportPath
        $shimExists = $pathArray -contains $shimPath
        
        if ($Action -eq "Add") {
            if ($teleportExists -and $shimExists) {
                Write-Host "[b2p] Already in $Scope PATH" -ForegroundColor Yellow
                return
            }
            $newArray = @($teleportPath, $shimPath) + ($pathArray | Where-Object { $_ -ne $teleportPath -and $_ -ne $shimPath })
            $newPath = $newArray -join ';'
            [Environment]::SetEnvironmentVariable('PATH', $newPath, $Scope)
            Write-B2PAudit "Added b2p to $Scope PATH"
            Write-Host "[b2p] $Scope PATH updated. Restart terminal to apply" -ForegroundColor Green
        } elseif ($Action -eq "Remove") {
            $newArray = $pathArray | Where-Object { $_ -ne $teleportPath -and $_ -ne $shimPath }
            $newPath = $newArray -join ';'
            [Environment]::SetEnvironmentVariable('PATH', $newPath, $Scope)
            Write-B2PAudit "Removed b2p from $Scope PATH"
            Write-Host "[b2p] $Scope PATH cleaned. Restart terminal to apply" -ForegroundColor Green
        }
    } catch {
        Write-B2PAudit "Failed to update PATH: $_" "ERROR"
        Write-Host "[b2p] Error: $_" -ForegroundColor Red
    }
}

function Set-B2PLatestLink {
    param([String]$AppName, [String]$TargetVersion)
    $appRoot = Join-Path $B2P_APPS $AppName
    $latestLink = Join-Path $appRoot "latest"
    $targetPath = Join-Path $appRoot $TargetVersion
    
    if (-not (Test-Path $targetPath)) {
        Write-Host "[b2p] Version $TargetVersion not found" -ForegroundColor Red
        return $false
    }
    
    try {
        # Remove old symlink if exists
        if (Test-Path $latestLink) {
            $linkInfo = Get-Item $latestLink -Force
            if ($linkInfo.LinkType -eq "SymbolicLink") {
                Remove-Item $latestLink -Force
            } elseif ($linkInfo -is [System.IO.DirectoryInfo]) {
                Write-Host "[b2p] Warning: '$latestLink' exists but is not a symlink. Removing..." -ForegroundColor Yellow
                Remove-Item $latestLink -Recurse -Force
            }
        }
        
        # Create new symlink
        $null = New-Item -ItemType SymbolicLink -Path $latestLink -Target $targetPath -Force
        Write-B2PAudit "Latest link updated for $AppName -> $TargetVersion"
        Write-Host "[b2p] Latest link updated: $AppName -> $TargetVersion" -ForegroundColor Green
        return $true
    } catch {
        Write-B2PAudit "Failed to set latest link: $_" "ERROR"
        Write-Host "[b2p] Error creating symlink: $_" -ForegroundColor Red
        return $false
    }
}

function Install-B2PApp {
    param (
        [Object]$Manifest, 
        [String]$Slot,           # 'latest' or fixed version
        [String]$OriginUrl,      # URL from where i.s came (to download manifest/uninstall from right place)
        [Switch]$Silent, 
        [ScriptBlock]$PreInstall, 
        [ScriptBlock]$PostInstall
    )

    $AppName = $Manifest.Name.ToLower()
    $InstallDir = Join-Path $B2P_APPS "$AppName\$Slot"
    
    # 1. Update check (if slot is 'latest' and already exists)
    if ($Slot -eq "latest" -and (Test-Path $InstallDir)) {
        $localMetaPath = Join-Path $InstallDir "b2p-metadata.json"
        if (Test-Path $localMetaPath) {
            $localMeta = Get-Content $localMetaPath | ConvertFrom-Json
            if ($localMeta.RealVersion -eq $Manifest.Version) {
                Write-Host "[b2p] You already have the latest version ($($Manifest.Version)) in 'latest' slot." -ForegroundColor Green
                return
            }
        }
        Write-Host "[b2p] New version detected ($($Manifest.Version)). Cleaning 'latest' slot..." -ForegroundColor Cyan
        Uninstall-B2PApp -Name $Manifest.Name -Version "latest"
    }

    if ($PreInstall) { & $PreInstall }

    # 2. Download and extraction
    $urlExt = [System.IO.Path]::GetExtension($Manifest.Url)
    if ([string]::IsNullOrWhiteSpace($urlExt) -or $urlExt -eq ".tmp") { $urlExt = ".zip" }
    $tempFile = Join-Path $env:TEMP "$([guid]::NewGuid().ToString())$urlExt"
    
    Write-Host "`n[b2p] Downloading $($Manifest.Name) ($Slot)..." -ForegroundColor Cyan
    try {
        # Try BITS first (PS5 only), fallback to Invoke-WebRequest
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Start-BitsTransfer -Source $Manifest.Url -Destination $tempFile -Priority Foreground -ErrorAction Stop
        } else {
            throw "PS7+ detected, using Invoke-WebRequest"
        }
    } catch {
        # BITS failed or not available, use Invoke-WebRequest
        Invoke-WebRequest -Uri $Manifest.Url -OutFile $tempFile -ErrorAction Stop
    }

    New-Item $InstallDir -ItemType Directory -Force | Out-Null
    Write-Host ">>> Installing to $InstallDir..." -ForegroundColor Gray
    # if the downloaded file isn't a zip archive, just move it instead of extracting
    switch ($urlExt.ToLower()) {
        '.zip' {
            Expand-Archive -Path $tempFile -DestinationPath $InstallDir -Force
        }
        default {
            # determine a reasonable filename: prefer the name in the URL, fall
            # back to the temp file name if that's unavailable
            $filename = [System.IO.Path]::GetFileName($Manifest.Url)
            if ([string]::IsNullOrEmpty($filename)) { $filename = Split-Path $tempFile -Leaf }
            $dest = Join-Path $InstallDir $filename
            Move-Item -Path $tempFile -Destination $dest -Force
        }
    }
    # temp file may already have been moved above; ignore errors
    Remove-Item $tempFile -ErrorAction SilentlyContinue

    # 3. Subfolder cleanup (flattening)
    $sub = Get-ChildItem $InstallDir -Directory | Select-Object -First 1
    if ($sub -and $sub.Name -like "*$($Manifest.Name)*") {
        Get-ChildItem $sub.FullName | Move-Item -Destination $InstallDir -Force
        Remove-Item $sub.FullName -Recurse -Force
    }

    # 4. Metadata and exposure
    $meta = @{ 
        Name = $Manifest.Name; 
        DisplayVersion = $Slot; 
        RealVersion = $Manifest.Version; 
        BinPath = Join-Path $InstallDir $Manifest.RelativeBinPath;
        CoreVersion = $B2P_CORE_VERSION;
        InstallDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss");
        Exposures = @{ Teleports = @(); Shims = @() }
    }

    # Create teleports (pass app name for later symlink usage)
    $meta.Exposures.Teleports = Create-B2PTeleports -Name $Manifest.Name -Version $Slot -BinPath $meta.BinPath -AppName $AppName
    
    # Create shims from manifest
    if ($Manifest.Shims) {
        foreach ($s in $Manifest.Shims) {
            $sList = Create-B2PShim -BinaryPath (Join-Path $meta.BinPath $s.bin) -Alias $s.alias -Version $Slot -AppName $AppName
            $meta.Exposures.Shims += $sList
        }
    }

    # Save metadata file
    $meta | ConvertTo-Json -Depth 5 | Out-File (Join-Path $InstallDir "b2p-metadata.json") -Encoding UTF8

    # 5. Sync uninstall.ps1 (fetch from SAME origin as i.s script)
    Write-Host ">>> Syncing uninstaller..." -ForegroundColor Gray
    $unSource = $OriginUrl -replace 'i.s$', 'uninstall.ps1'
    try {
        Invoke-WebRequest -Uri $unSource -OutFile (Join-Path $InstallDir "uninstall.ps1") -ErrorAction Stop
    } catch {
        # Fallback if file does not exist on server
        $genUn = "param(`$N='$($Manifest.Name)', `$V='$Slot'); . (Join-Path `$env:USERPROFILE '.b2p\bin\core.ps1'); Uninstall-B2PApp -Name `$N -Version `$V"
        $genUn | Out-File (Join-Path $InstallDir "uninstall.ps1") -Encoding UTF8
    }

    if ($PostInstall) { & $PostInstall }
    Write-Host "[b2p] Successfully installed in slot '$Slot'." -ForegroundColor Green
}

function Create-B2PTeleports {
    param($Name, $Version, $BinPath, $AppName)
    $created = @()
    
    # Versioned teleport uses actual BinPath
    $teleName = if ($Version -eq "latest") { "$Name-latest.bat" } else { "$Name-v$Version.bat" }
    $content = "@echo off`nchcp 65001 > nul`nset B2P_BIN=$BinPath`nif `"%~1`"==`"`" (echo $Name $Version) else ( `"%B2P_BIN%\%~1`" %~2 %~3 %~4 %~5 %~6 )"
    
    $p = Join-Path $B2P_TELEPORTS $teleName
    $content | Out-File $p -Encoding UTF8
    $created += $p
    
    # Generic teleport points to 'latest' symlink if this is first setup
    if (-not (Test-Path (Join-Path $B2P_TELEPORTS "$Name.bat"))) {
        $genericBinPath = Join-Path $B2P_APPS "$AppName\latest\bin"
        $genericContent = "@echo off`nchcp 65001 > nul`nset B2P_BIN=$genericBinPath`nif `"%~1`"==`"`" (echo $Name latest) else ( `"%B2P_BIN%\%~1`" %~2 %~3 %~4 %~5 %~6 )"
        $gp = Join-Path $B2P_TELEPORTS "$Name.bat"
        $genericContent | Out-File $gp -Encoding UTF8
        $created += $gp
    }
    
    return $created
}

function Create-B2PShim {    param($BinaryPath, $Alias, $Version, $AppName)
    $created = @()
    
    # Create versioned shim (always)
    $shimName = if ($Version -eq "latest") { "$Alias.bat" } else { "$Alias-v$Version.bat" }
    $p = Join-Path $B2P_SHIMS $shimName
    $content = "@echo off`nchcp 65001 > nul`n`"$BinaryPath`" %*"
    $content | Out-File $p -Encoding UTF8
    $created += $p
    
    # Create generic shim pointing to 'latest' symlink if this is first install or update
    if ($Version -ne "latest" -and -not (Test-Path (Join-Path $B2P_SHIMS "$Alias.bat"))) {
        $genericPath = Join-Path $B2P_SHIMS "$Alias.bat"
        $latestBinPath = Join-Path $B2P_APPS "$AppName\latest\bin\$(Split-Path $BinaryPath -Leaf)"
        $genericContent = "@echo off`nchcp 65001 > nul`n`"$latestBinPath`" %*"
        $genericContent | Out-File $genericPath -Encoding UTF8
        $created += $genericPath
    }
    
    return $created
}

function Uninstall-B2PApp {
    param($Name, $Version)
    $AppName = $Name.ToLower()
    $AppRoot = Join-Path $B2P_APPS $AppName
    if (Test-Path $AppRoot) { Set-Location $AppRoot }

    Write-Host "[b2p] Removing $Name ($Version)..." -ForegroundColor Yellow

    # If uninstalling 'latest', follow symlink to get real version
    $versToUninstall = $Version
    if ($Version -eq "latest") {
        $latestLink = Join-Path $AppRoot "latest"
        if (Test-Path $latestLink) {
            $linkInfo = Get-Item $latestLink -Force
            if ($linkInfo.LinkType -eq "SymbolicLink") {
                $target = $linkInfo.Target
                if ($target -match "\\(v[\d.]+)") { $versToUninstall = $matches[1] }
            }
        }
    }

    $versionsToRemove = if ($versToUninstall -eq "all") { 
        if (Test-Path $AppRoot) { Get-ChildItem $AppRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name } 
    } else { @($versToUninstall) }

    foreach ($v in $versionsToRemove) {
        $metaFile = Join-Path $AppRoot "$v\b2p-metadata.json"
        if (Test-Path $metaFile) {
            $meta = Get-Content $metaFile | ConvertFrom-Json
            foreach ($file in $meta.Exposures.Teleports) { if (Test-Path $file) { Remove-Item $file -Force } }
            foreach ($file in $meta.Exposures.Shims) { if (Test-Path $file) { Remove-Item $file -Force } }
        }
        $targetDir = Join-Path $AppRoot $v
        if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Always remove 'latest' symlink if it exists when removing versions
    $latestLink = Join-Path $AppRoot "latest"
    if (Test-Path $latestLink) {
        $linkInfo = Get-Item $latestLink -Force
        if ($linkInfo.LinkType -eq "SymbolicLink") {
            Remove-Item $latestLink -Force
        }
    }

    if ($versToUninstall -eq "all") {
        Set-Location $B2P_APPS
        Remove-Item $AppRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[b2p] Cleanup of '$Version' complete." -ForegroundColor Green
}