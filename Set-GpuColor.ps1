# Set-GpuColor.ps1 — proof of concept: set the MSI 4090's RGB to a static color.
# Usage: .\Set-GpuColor.ps1 -R 255 -G 0 -B 0 [-Brightness 5]
param(
    [byte]$R = 255,
    [byte]$G = 0,
    [byte]$B = 0,
    [ValidateRange(1,5)][byte]$Brightness = 5
)

Add-Type -Path "$PSScriptRoot\MsiGpuRgb.cs"

[AuraGpuBridge.MsiGpu]::Connect()
Write-Host $([AuraGpuBridge.MsiGpu]::Status)

[AuraGpuBridge.MsiGpu]::SetStatic($R, $G, $B, $Brightness)

# Read back registers to verify the controller accepted the writes
$mode = [AuraGpuBridge.MsiGpu]::ReadReg(0x22)
$rr   = [AuraGpuBridge.MsiGpu]::ReadReg(0x30)
$gg   = [AuraGpuBridge.MsiGpu]::ReadReg(0x31)
$bb   = [AuraGpuBridge.MsiGpu]::ReadReg(0x32)
Write-Host ("Readback: mode=0x{0:X2} (expect 0x13)  R={1} G={2} B={3} (expect {4},{5},{6})" -f $mode, $rr, $gg, $bb, $R, $G, $B)

if ($mode -eq 0x13 -and $rr -eq $R -and $gg -eq $G -and $bb -eq $B) {
    Write-Host "SUCCESS: controller confirmed static color." -ForegroundColor Green
} else {
    Write-Host "WARNING: readback mismatch — writes may not have been accepted." -ForegroundColor Yellow
}
