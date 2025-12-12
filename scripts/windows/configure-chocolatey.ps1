#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Chocolatey and font packages from fonts.json.

.DESCRIPTION
    Idempotent script that installs Chocolatey if missing, then installs
    font packages only if they're not already present.

.NOTES
    Author: jsh automation
    Requires: Administrator privileges
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\..\configs\windows\fonts.json"
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

function Test-ChocolateyInstalled {
    try {
        $null = Get-Command choco -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Install-Chocolatey {
    Write-Status "Installing Chocolatey..." -Type Info

    try {
        # Set execution policy for the process
        Set-ExecutionPolicy Bypass -Scope Process -Force

        # Download and execute the Chocolatey install script
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

        # Refresh environment variables
        $env:ChocolateyInstall = [System.Environment]::GetEnvironmentVariable("ChocolateyInstall", "Machine")
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        # Import Chocolatey profile
        $chocoProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
        if (Test-Path $chocoProfile) {
            Import-Module $chocoProfile -Force
        }

        if (Test-ChocolateyInstalled) {
            Write-Status "Chocolatey installed successfully" -Type Success
            return $true
        }
        else {
            throw "Chocolatey installation completed but command not available"
        }
    }
    catch {
        Write-Status "Failed to install Chocolatey: $_" -Type Error
        return $false
    }
}

function Test-ChocoPackageInstalled {
    param([string]$PackageName)

    try {
        $result = choco list --local-only --exact $PackageName 2>&1
        return ($result -match $PackageName)
    }
    catch {
        return $false
    }
}

function Get-NerdFontPackageName {
    param([string]$FontName)

    # Map common font names to their Chocolatey Nerd Font package names
    $fontMappings = @{
        'JetBrainsMono'    = 'nerd-fonts-JetBrainsMono'
        'FiraCode'         = 'nerd-fonts-FiraCode'
        'Hack'             = 'nerd-fonts-Hack'
        'CascadiaCode'     = 'nerd-fonts-CascadiaCode'
        'SourceCodePro'    = 'nerd-fonts-SourceCodePro'
        'UbuntuMono'       = 'nerd-fonts-UbuntuMono'
        'Meslo'            = 'nerd-fonts-Meslo'
        'RobotoMono'       = 'nerd-fonts-RobotoMono'
        'Inconsolata'      = 'nerd-fonts-Inconsolata'
        'DejaVuSansMono'   = 'nerd-fonts-DejaVuSansMono'
    }

    if ($fontMappings.ContainsKey($FontName)) {
        return $fontMappings[$FontName]
    }

    # Default: assume it's already a valid package name or try nerd-fonts prefix
    return "nerd-fonts-$FontName"
}

function Install-ChocoPackage {
    param([string]$PackageName)

    Write-Status "Installing $PackageName..." -Type Info
    try {
        $result = choco install $PackageName -y --no-progress 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Status "$PackageName installed successfully" -Type Success
            return $true
        }
        else {
            Write-Status "Failed to install $PackageName" -Type Error
            Write-Host $result -ForegroundColor Gray
            return $false
        }
    }
    catch {
        Write-Status "Error installing ${PackageName}: $_" -Type Error
        return $false
    }
}

# Main execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  Chocolatey & Fonts Installation" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

# Verify running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Status "This script requires Administrator privileges" -Type Error
    exit 1
}

# Check/Install Chocolatey
if (-not (Test-ChocolateyInstalled)) {
    if (-not (Install-Chocolatey)) {
        Write-Status "Cannot proceed without Chocolatey" -Type Error
        exit 1
    }
}
else {
    Write-Status "Chocolatey is already installed" -Type Success
}

$chocoVersion = (choco --version 2>&1) -replace '\s+', ''
Write-Status "Chocolatey version: $chocoVersion" -Type Info

# Load font list
$configFullPath = Resolve-Path $ConfigPath -ErrorAction Stop
Write-Status "Loading fonts from: $configFullPath" -Type Info

$fonts = Get-Content $configFullPath -Raw | ConvertFrom-Json

if (-not $fonts -or $fonts.Count -eq 0) {
    Write-Status "No fonts found in configuration" -Type Warning
    exit 0
}

Write-Status "Found $($fonts.Count) fonts to process" -Type Info
Write-Host ""

# Track results
$installed = 0
$skipped = 0
$failed = 0

foreach ($font in $fonts) {
    $packageName = Get-NerdFontPackageName -FontName $font

    if (Test-ChocoPackageInstalled -PackageName $packageName) {
        Write-Status "$packageName is already installed" -Type Success
        $skipped++
    }
    else {
        if (Install-ChocoPackage -PackageName $packageName) {
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
