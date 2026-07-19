# Install-Task.ps1 — register the AuraGpuBridge scheduled task (hidden, at logon).
# Run from the folder containing Bridge.ps1.
$ErrorActionPreference = 'Stop'

# Task Scheduler can't resolve the Microsoft Store pwsh alias from PATH, so pin
# the full path to whichever pwsh this is running under.
$pwshPath = (Get-Process -Id $PID).Path
if (-not $pwshPath -or $pwshPath -notmatch 'pwsh') {
    $pwshPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
    if (-not (Test-Path $pwshPath)) { $pwshPath = 'pwsh.exe' }
}

$bridge   = Join-Path $PSScriptRoot 'Bridge.ps1'
$action   = New-ScheduledTaskAction -Execute $pwshPath -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bridge`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName 'AuraGpuBridge' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Sync ASUS Aura lighting effect to MSI GPU RGB (AuraGpuBridge)' -Force | Out-Null
Start-ScheduledTask -TaskName 'AuraGpuBridge'

Write-Host "AuraGpuBridge task registered and started ($pwshPath)."
Write-Host "Watch $PSScriptRoot\bridge.log to see what it's doing."
