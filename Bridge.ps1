# Bridge.ps1 — Aura Sync -> MSI 4090 RGB bridge.
# Watches the Aura 3.0 engine script that Armoury Crate writes whenever the lighting
# effect changes, maps the effect + color onto the closest ITE9 hardware mode, and
# pushes it to the GPU over NVAPI I2C.
#
# Usage:  .\Bridge.ps1          run the watch loop (for the scheduled task)
#         .\Bridge.ps1 -Once    parse + apply once, print what it did, exit
param(
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$AuraScript = 'C:\ProgramData\ASUS\RogAura30\SetV2EngineScript.xml'
$EneHalLog  = 'C:\ProgramData\ASUS\ARMOURY CRATE Diagnosis\OptionHAL\EneHal.log'
$LogFile    = "$PSScriptRoot\bridge.log"

Add-Type -Path "$PSScriptRoot\MsiGpuRgb.cs"

function Write-Log([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    if ($Once) { Write-Host $line }
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 512KB) {
            Get-Content $LogFile -Tail 200 | Set-Content $LogFile
        }
        Add-Content $LogFile $line
    } catch {}
}

function Convert-HslToRgb([double]$h, [double]$s, [double]$l) {
    # standard HSL, h/s/l all 0..1; returns byte[3] R,G,B
    if ($s -eq 0) { $v = [byte][Math]::Round($l * 255); return @($v, $v, $v) }
    $q = if ($l -lt 0.5) { $l * (1 + $s) } else { $l + $s - $l * $s }
    $p = 2 * $l - $q
    $rgb = foreach ($t in (($h + 1/3), $h, ($h - 1/3))) {
        if ($t -lt 0) { $t += 1 }; if ($t -gt 1) { $t -= 1 }
        $c = if ($t -lt 1/6) { $p + ($q - $p) * 6 * $t }
             elseif ($t -lt 1/2) { $q }
             elseif ($t -lt 2/3) { $p + ($q - $p) * (2/3 - $t) * 6 }
             else { $p }
        [byte][Math]::Round($c * 255)
    }
    return $rgb
}

function Get-AuraState {
    # Returns @{ Effect = 'Star'; R=..; G=..; B=.. } or $null on parse failure
    try {
        [xml]$xml = Get-Content $AuraScript -Raw
    } catch { return $null }

    $effects = @($xml.SelectNodes('//effect[initColor]'))
    if ($effects.Count -eq 0) { return $null }

    # Effect keys look like "StarSingleEff0" / "StaticBackGroundSingleEff3".
    # The primary effect is the non-background one; pure static setups only have the background.
    $primary = $null
    foreach ($e in $effects) {
        $base = $e.key -replace 'SingleEff\d*$','' -replace '\d+$',''
        if ($base -and $base -ne 'StaticBackGround') { $primary = @{ Name = $base; Node = $e }; break }
    }
    if (-not $primary) {
        $e = $effects | Where-Object { $_.key -match '^StaticBackGround' } | Select-Object -First 1
        if (-not $e) { $e = $effects[0] }
        $primary = @{ Name = 'Static'; Node = $e }
    }

    $init = $primary.Node.initColor
    if (-not $init) { return $null }
    $rgb = Convert-HslToRgb ([double]$init.hue) ([double]$init.saturation) ([double]$init.lightness)

    # HSL lightness 0.5 is full saturation; Aura static uses ~0.5. Boost very dim
    # backgrounds so the GPU isn't near-black on static-only profiles.
    if (($rgb[0] + $rgb[1] + $rgb[2]) -lt 30) {
        $rgb = Convert-HslToRgb ([double]$init.hue) ([double]$init.saturation) 0.5
    }

    return @{ Effect = $primary.Name; R = $rgb[0]; G = $rgb[1]; B = $rgb[2] }
}

function Apply-ToGpu($state) {
    # Map Aura effect names to the closest ITE9 hardware mode
    $mode = switch -Regex ($state.Effect) {
        '^Static'            { 'static';    break }
        '^Breath'            { 0x04;        break }   # breathing
        '^Strob|^Flash'      { 0x02;        break }   # flashing
        '^Rainbow|^Wave'     { 0x08;        break }   # rainbow wave (color ignored)
        '^ColorCycle|^Cycle' { 0x07;        break }   # magic / color cycle (color ignored)
        '^Comet|^Meteor'     { 0x16;        break }   # meteor
        '^Star'              { 0x04;        break }   # star/twinkle -> breathing, closest pulse feel
        default              { 'static';    break }
    }

    if ($mode -eq 'static') {
        [AuraGpuBridge.MsiGpu]::SetStatic($state.R, $state.G, $state.B, 5)
        Write-Log ("Applied STATIC  R={0} G={1} B={2}  (Aura effect '{3}')" -f $state.R, $state.G, $state.B, $state.Effect)
    } else {
        [AuraGpuBridge.MsiGpu]::SetEffect([byte]$mode, $state.R, $state.G, $state.B, 5, 1)
        Write-Log ("Applied mode 0x{0:X2}  R={1} G={2} B={3}  (Aura effect '{4}')" -f [int]$mode, $state.R, $state.G, $state.B, $state.Effect)
    }
}

# --- EneHal.log tail: on/off detection ----------------------------------------
# Armoury Crate's ENE DRAM HAL streams per-LED frames ("SetEft...Color:...") while
# lighting is on; "Aura off" writes all-zero frames and the stream stops. We tail
# the log: last frame black + stream idle -> lighting is off.

$script:enePos          = -1                 # file offset already consumed
$script:eneLastFrameOff = $false             # last seen SetEft frame was all-zero
$script:eneLastActivity = [datetime]::MinValue

function Read-EneChunk([long]$from, [long]$to) {
    $fs = [System.IO.File]::Open($EneHalLog, 'Open', 'Read', [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $fs.Seek($from, 'Begin') | Out-Null
        $buf = New-Object byte[] ($to - $from)
        $n = $fs.Read($buf, 0, $buf.Length)
        return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
}

function Update-EneState {
    # Returns 'off', 'on', or $null (nothing new / unknown). Also maintains script state.
    $f = Get-Item $EneHalLog -ErrorAction SilentlyContinue
    if (-not $f) { return $null }

    if ($script:enePos -lt 0 -or $f.Length -lt $script:enePos) {
        # first run or log rotated: read only the last 64KB to find current state
        $script:enePos = [Math]::Max(0, $f.Length - 64KB)
        $script:eneLastActivity = $f.LastWriteTimeUtc
    }

    $newData = $false
    if ($f.Length -gt $script:enePos) {
        $text = Read-EneChunk $script:enePos $f.Length
        $script:enePos = $f.Length
        $frames = [regex]::Matches($text, 'SetEft\(Idx:\d+\)[^,]*,Color:([0-9A-Fa-f,]+)')
        if ($frames.Count -gt 0) {
            $newData = $true
            $script:eneLastActivity = (Get-Date).ToUniversalTime()
            $last = $frames[$frames.Count - 1].Groups[1].Value.TrimEnd(',')
            $script:eneLastFrameOff = -not (($last -split ',') | Where-Object { $_ -notmatch '^0+$' })
        }
    }

    if ($newData -and -not $script:eneLastFrameOff) { return 'on' }
    # off = last frame black and the stream has been quiet for a few seconds
    if ($script:eneLastFrameOff -and ((Get-Date).ToUniversalTime() - $script:eneLastActivity).TotalSeconds -gt 8) { return 'off' }
    return $null
}

# --- main ---------------------------------------------------------------------

# single-instance guard (a killed instance leaves the mutex abandoned; that still
# counts as acquired)
$mutex = New-Object System.Threading.Mutex($false, 'Global\AuraGpuBridge')
try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { Write-Log 'Another instance is running; exiting.'; exit 0 }

try {
    [AuraGpuBridge.MsiGpu]::Connect()
    Write-Log ([AuraGpuBridge.MsiGpu]::Status)

    $lastWrite = [datetime]::MinValue
    $lastApply = [datetime]::MinValue
    $lastState = ''
    $gpuOff    = $false

    # initial state: if the last HAL frame on record is black, lighting is off right now
    Update-EneState | Out-Null
    if ($script:eneLastFrameOff) {
        try {
            [AuraGpuBridge.MsiGpu]::SetOff()
            $gpuOff    = $true
            $lastWrite = (Get-Item $AuraScript -ErrorAction SilentlyContinue).LastWriteTimeUtc
            Write-Log 'Startup: Aura lighting is OFF -> GPU RGB off'
        } catch { Write-Log "Startup off apply failed: $_" }
    }

    while ($true) {
        # --- lighting on/off tracking via ENE HAL frame stream ---
        $eneState = Update-EneState
        if ($eneState -eq 'off' -and -not $gpuOff) {
            try {
                [AuraGpuBridge.MsiGpu]::SetOff()
                [AuraGpuBridge.MsiGpu]::Save()
                $gpuOff = $true
                Write-Log 'Aura lighting is OFF -> GPU RGB off'
            } catch { Write-Log "Off apply failed: $_" }
        }
        elseif ($eneState -eq 'on' -and $gpuOff) {
            $gpuOff    = $false
            $lastState = ''                       # force re-apply of current effect
            $lastApply = [datetime]::MinValue
            Write-Log 'Aura lighting is back ON -> restoring effect'
        }

        $doApply = $false
        $mtime = (Get-Item $AuraScript -ErrorAction SilentlyContinue).LastWriteTimeUtc
        if ($mtime -and $mtime -ne $lastWrite) { $doApply = $true; $gpuOff = $false }
        # periodic re-apply heals driver resets / sleep-resume wiping controller state
        if (((Get-Date).ToUniversalTime() - $lastApply).TotalMinutes -ge 5) { $doApply = $true }
        if ($gpuOff) { $doApply = $false }

        if ($doApply) {
            $state = Get-AuraState
            if ($state) {
                $key = '{0}|{1}|{2}|{3}' -f $state.Effect, $state.R, $state.G, $state.B
                $isChange = ($key -ne $lastState)
                try {
                    Apply-ToGpu $state
                    if ($isChange) { [AuraGpuBridge.MsiGpu]::Save() }   # persist across reboots
                    $lastState = $key
                    $lastWrite = $mtime
                    $lastApply = (Get-Date).ToUniversalTime()
                } catch {
                    Write-Log "Apply failed: $_"
                    Start-Sleep -Seconds 10
                    try { [AuraGpuBridge.MsiGpu]::Connect() } catch {}
                }
            } else {
                Write-Log "Could not parse Aura state from $AuraScript"
                $lastWrite = $mtime
                $lastApply = (Get-Date).ToUniversalTime()
            }
        }

        if ($Once) { break }
        Start-Sleep -Seconds 3
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
