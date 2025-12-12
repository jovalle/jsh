#Requires -Version 5.1
<#
.SYNOPSIS
    Installs packages from winget.json using Windows Package Manager (winget).

.DESCRIPTION
    Idempotent script that checks each package's installation status before
    attempting to install. Only installs missing packages.

.NOTES
    Author: jsh automation
    Requires: Windows 10/11 with winget installed
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\..\configs\windows\winget.json"
)

$ErrorActionPreference = 'Stop'

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    $symbols = @{
        'Info'    = '[*]'
        'Success' = '[+]'
        'Warning' = '[!]'
        'Error'   = '[X]'
    }
    $colors = @{
        'Info'    = 'Cyan'
        'Success' = 'Green'
        'Warning' = 'Yellow'
        'Error'   = 'Red'
    }
    Write-Host "$($symbols[$Type]) $Message" -ForegroundColor $colors[$Type]
}

function Test-WingetInstalled {
    try {
        $null = Get-Command winget -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Install-Winget {
    Write-Status "Winget not found. Attempting to install..." -Type Warning

    # Try to install via App Installer from Microsoft Store
    try {
        # Check if running on Windows 11 or Windows 10 with App Installer
        $appInstaller = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
        if ($appInstaller) {
            Write-Status "App Installer is present but winget not in PATH. Attempting repair..." -Type Warning
            Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction Stop
        }
        else {
            # Download and install the latest version
            Write-Status "Downloading winget from GitHub releases..." -Type Info
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
            $msixBundle = $releases.assets | Where-Object { $_.name -match "\.msixbundle$" } | Select-Object -First 1
            $vcLibs = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
            $uiXaml = $releases.assets | Where-Object { $_.name -match "Microsoft\.UI\.Xaml.*\.appx$" } | Select-Object -First 1

            $tempDir = Join-Path $env:TEMP "winget-install"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

            # Download dependencies
            Write-Status "Downloading VCLibs..." -Type Info
            $vcLibsPath = Join-Path $tempDir "VCLibs.appx"
            Invoke-WebRequest -Uri $vcLibs -OutFile $vcLibsPath

            Write-Status "Downloading winget bundle..." -Type Info
            $bundlePath = Join-Path $tempDir $msixBundle.name
            Invoke-WebRequest -Uri $msixBundle.browser_download_url -OutFile $bundlePath

            # Install
            Write-Status "Installing VCLibs..." -Type Info
            Add-AppxPackage -Path $vcLibsPath -ErrorAction SilentlyContinue

            Write-Status "Installing winget..." -Type Info
            Add-AppxPackage -Path $bundlePath

            # Cleanup
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        if (Test-WingetInstalled) {
            Write-Status "Winget installed successfully" -Type Success
            return $true
        }
        else {
            throw "Winget installation completed but command not available"
        }
    }
    catch {
        Write-Status "Failed to install winget: $_" -Type Error
        Write-Status "Please install winget manually from the Microsoft Store (App Installer)" -Type Warning
        return $false
    }
}

function Test-PackageInstalled {
    param([string]$PackageId)

    try {
        $result = winget list --id $PackageId --accept-source-agreements 2>&1
        return ($result -match $PackageId.Split('.')[-1])
    }
    catch {
        return $false
    }
}

function Install-WingetPackage {
    param([string]$PackageId)

    Write-Status "Installing $PackageId..." -Type Info
    try {
        $result = winget install --id $PackageId --accept-package-agreements --accept-source-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0 -or $result -match "already installed") {
            Write-Status "$PackageId installed successfully" -Type Success
            return $true
        }
        else {
            Write-Status "Failed to install $PackageId" -Type Error
            return $false
        }
    }
    catch {
        Write-Status "Error installing ${PackageId}: $_" -Type Error
        return $false
    }
}

# Main execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  Winget Package Installation           " -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

# Verify winget is available
if (-not (Test-WingetInstalled)) {
    if (-not (Install-Winget)) {
        Write-Status "Cannot proceed without winget" -Type Error
        exit 1
    }
}

$wingetVersion = (winget --version 2>&1) -replace '\s+', ''
Write-Status "Winget version: $wingetVersion" -Type Info

# Load package list
$configFullPath = Resolve-Path $ConfigPath -ErrorAction Stop
Write-Status "Loading packages from: $configFullPath" -Type Info

$packages = Get-Content $configFullPath -Raw | ConvertFrom-Json

if (-not $packages -or $packages.Count -eq 0) {
    Write-Status "No packages found in configuration" -Type Warning
    exit 0
}

Write-Status "Found $($packages.Count) packages to process" -Type Info
Write-Host ""

# Track results
$installed = 0
$skipped = 0
$failed = 0

foreach ($package in $packages) {
    if (Test-PackageInstalled -PackageId $package) {
        Write-Status "$package is already installed" -Type Success
        $skipped++
    }
    else {
        if (Install-WingetPackage -PackageId $package) {
            $installed++
        }
        else {
            $failed++
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  Summary" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Status "Installed: $installed" -Type Info
Write-Status "Already installed: $skipped" -Type Info
if ($failed -gt 0) {
    Write-Status "Failed: $failed" -Type Error
}
Write-Host ""

exit $failed
