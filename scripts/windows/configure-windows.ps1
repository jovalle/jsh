#Requires -Version 5.1
<#
.SYNOPSIS
    Master configuration script for Windows hosts.

.DESCRIPTION
    Orchestrates the execution of all Windows configuration scripts with
    a single UAC elevation prompt. Runs winget packages and Chocolatey/fonts
    installation in sequence.

.PARAMETER SkipWinget
    Skip winget package installation.

.PARAMETER SkipChocolatey
    Skip Chocolatey and font installation.

.PARAMETER Force
    Force reconfiguration even if already configured.

.EXAMPLE
    .\configure-windows.ps1
    Runs all configuration scripts.

.EXAMPLE
    .\configure-windows.ps1 -SkipWinget
    Runs all except winget package installation.

.NOTES
    Author: jsh automation
    Requires: Windows 10/11
#>

[CmdletBinding()]
param(
    [switch]$SkipWinget,
    [switch]$SkipChocolatey,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Header')]
        [string]$Type = 'Info'
    )
    $symbols = @{
        'Info'    = '[*]'
        'Success' = '[+]'
        'Warning' = '[!]'
        'Error'   = '[X]'
        'Header'  = '[>]'
    }
    $colors = @{
        'Info'    = 'Cyan'
        'Success' = 'Green'
        'Warning' = 'Yellow'
        'Error'   = 'Red'
        'Header'  = 'Magenta'
    }
    Write-Host "$($symbols[$Type]) $Message" -ForegroundColor $colors[$Type]
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedScript {
    param(
        [string]$ScriptPath,
        [string]$Arguments = ""
    )

    $scriptName = Split-Path $ScriptPath -Leaf

    if (-not (Test-Path $ScriptPath)) {
        Write-Status "Script not found: $ScriptPath" -Type Error
        return $false
    }

    Write-Status "Executing: $scriptName" -Type Header
    Write-Host ""

    try {
        if ($Arguments) {
            & $ScriptPath @Arguments
        }
        else {
            & $ScriptPath
        }

        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        else {
            Write-Status "$scriptName completed with errors (exit code: $LASTEXITCODE)" -Type Warning
            return $false
        }
    }
    catch {
        Write-Status "Failed to execute ${scriptName}: $_" -Type Error
        return $false
    }
}

# Banner
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         Windows Host Configuration (jsh)                      " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as administrator
if (-not (Test-Administrator)) {
    Write-Status "Requesting Administrator privileges..." -Type Warning
    Write-Host ""

    # Build arguments for elevated session
    $scriptArgs = @()
    if ($SkipWinget) { $scriptArgs += '-SkipWinget' }
    if ($SkipChocolatey) { $scriptArgs += '-SkipChocolatey' }
    if ($Force) { $scriptArgs += '-Force' }

    $argString = $scriptArgs -join ' '
    $scriptPath = $MyInvocation.MyCommand.Path
    $psCommand = "Set-Location '$ScriptDir'; & '$scriptPath' $argString; Read-Host 'Press Enter to close'"

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $psCommand -Wait
        exit 0
    }
    catch {
        Write-Status "Failed to elevate privileges: $_" -Type Error
        exit 1
    }
}

Write-Status "Running with Administrator privileges" -Type Success
Write-Host ""

# Track overall results
$results = @{
    Winget     = $null
    Chocolatey = $null
}

# Step 1: Winget packages
if (-not $SkipWinget) {
    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    $results.Winget = Invoke-ElevatedScript -ScriptPath (Join-Path $ScriptDir "configure-winget.ps1")
}
else {
    Write-Status "Skipping winget configuration" -Type Warning
    $results.Winget = $true
}

# Step 2: Chocolatey and fonts
if (-not $SkipChocolatey) {
    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    $results.Chocolatey = Invoke-ElevatedScript -ScriptPath (Join-Path $ScriptDir "configure-chocolatey.ps1")
}
else {
    Write-Status "Skipping Chocolatey configuration" -Type Warning
    $results.Chocolatey = $true
}

# Final summary
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                     Final Summary                           " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$allSuccess = $true

foreach ($key in $results.Keys) {
    if ($results[$key] -eq $null) {
        continue
    }
    elseif ($results[$key]) {
        Write-Status "$key configuration: Completed" -Type Success
    }
    else {
        Write-Status "$key configuration: Failed" -Type Error
        $allSuccess = $false
    }
}

Write-Host ""

if ($allSuccess) {
    Write-Status "All configurations completed successfully!" -Type Success
    Write-Host ""
    Write-Status "Recommended next steps:" -Type Info
    Write-Host "  1. Restart your terminal to pick up new environment variables" -ForegroundColor Gray
    Write-Host "  2. Review installed applications and sign in as needed" -ForegroundColor Gray
    exit 0
}
else {
    Write-Status "Some configurations failed. Review the output above." -Type Warning
    exit 1
}
