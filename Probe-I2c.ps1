# Probe-I2c.ps1 — check whether the ITE9 controller ACKs at 0x68 vs an empty address.
Add-Type -Path "$PSScriptRoot\MsiGpuRgb.cs"

$asm = [AuraGpuBridge.MsiGpu].Assembly

[AuraGpuBridge.MsiGpu]::Connect()
Write-Host $([AuraGpuBridge.MsiGpu]::Status)

# Reflection helper to call the private I2cTransfer with an arbitrary address is overkill;
# instead compare raw read results across several registers and probe a benign write.

# 1. Benign write to REG_UNKNOWN (0x2E) at the real address — should succeed (rc 0 -> no throw)
try {
    [AuraGpuBridge.MsiGpu]::WriteReg(0x2E, 0x00)
    Write-Host "Write to 0x68/reg 0x2E: OK (rc=0)"
} catch {
    Write-Host "Write to 0x68/reg 0x2E: FAILED - $_"
}

# 2. Read several registers; sentinel (<0) means NVAPI returned an error for the read
foreach ($reg in 0x22, 0x30, 0x36, 0x38, 0x46) {
    $v = [AuraGpuBridge.MsiGpu]::ReadReg($reg)
    Write-Host ("Read reg 0x{0:X2} -> {1}" -f $reg, $v)
}

# 3. ACK comparison: read-probe the real address vs addresses that should be empty.
foreach ($addr in 0x68, 0x69, 0x6A, 0x2C) {
    $rc = [AuraGpuBridge.MsiGpu]::ProbeRead($addr, 0x22)
    Write-Host ("Probe read addr 0x{0:X2} -> NVAPI status {1}" -f $addr, $rc)
}
