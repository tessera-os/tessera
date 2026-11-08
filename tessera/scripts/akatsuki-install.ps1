# Sony Xperia XZ3 H8416 Tessera two-phase fastboot installer.
# Default: checksum/identity/geometry preflight ONLY. No device changes.
# -Install erases Android userdata after flashing source to inactive system_a.
# -TestSystem attempts a RAM-only Tessera system boot after successful install.
# -Complete flashes boot_a, switching active slot only after confirmation.
param(
    [switch]$Install,
    [switch]$TestSystem,
    [switch]$Complete
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$fastboot = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\fastboot.exe'
$selectedCount = [int][bool]$Install + [int][bool]$TestSystem + [int][bool]$Complete
if ($selectedCount -gt 1) { throw 'Choose only one operation at a time.' }
if (!(Test-Path -LiteralPath $fastboot -PathType Leaf)) { throw "Missing fastboot: $fastboot" }

Write-Output 'Checking all Tessera installer payloads...'
foreach ($line in Get-Content -LiteralPath (Join-Path $dir 'SHA256SUMS')) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Invalid hash entry: $line" }
    $expected = $Matches[1]
    $name = $Matches[2]
    $path = Join-Path $dir $name
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing: $path" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Checksum mismatch: $name" }
}
$manifest = Get-Content -LiteralPath (Join-Path $dir 'MANIFEST.json') -Raw | ConvertFrom-Json
if ($manifest.device -ne 'Sony Xperia XZ3 H8416 / akatsuki' -or
    $manifest.target_partition -ne 'userdata') {
    throw 'Manifest does not describe the expected Xperia XZ3 installation.'
}
$activeSlot = [string]$manifest.retained_stock_slot
$targetSlot = [string]$manifest.boot_target_slot
if ($activeSlot -notin @('a','b') -or $targetSlot -notin @('a','b') -or
    $activeSlot -eq $targetSlot) {
    throw 'Manifest does not preserve one slot while targeting the other.'
}
$bootPartition = "boot_$targetSlot"
$systemPartition = "system_$targetSlot"
if ($manifest.source_partition -ne $systemPartition) {
    throw 'Manifest source partition does not match its inactive target slot.'
}
Write-Output ("Tessera system version: " + $manifest.system_version)

function FastbootResult([string[]]$arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $fastboot
    # All arguments here originate in trusted constants and a checked device
    # serial; no shell interpolation or PowerShell NativeCommandError parsing.
    $info.Arguments = (($arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + $_.Replace('"','\"') + '"' } else { $_ }
    }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($info)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $result = $stdout + "`n" + $stderr
    # On the Sony/Windows WinUSB combination, fastboot 36.0.0 has returned
    # process exit code 0 while printing FAILED (Write to device failed (no
    # link)). Never interpret such output as success or proceed to a second
    # flashing step when the first was silently rejected.
    if ($proc.ExitCode -ne 0 -or $result -match '(?i)\bFAILED\b|fastboot:\s*error|write to device failed|no link') {
        throw ("fastboot " + $arguments[0] + " failed: " + $result)
    }
    if ($arguments -contains 'flash' -or $arguments -contains 'boot' -or $arguments -contains 'set_active') {
        if ($result -notmatch '\bOKAY\b') {
            throw ("fastboot did not confirm an OKAY response: " + $result)
        }
    }
    return $result
}

$connected = FastbootResult -arguments @('devices', '-l')
$devices = @($connected -split "`r?`n" | Where-Object { $_ -match '^\S+\s+fastboot\b' })
if ($devices.Count -ne 1) { throw "Expected one fastboot-connected phone; found $($devices.Count)." }
$serial = ($devices[0] -split '\s+')[0]
function GetVar([string]$name) {
    $answer = FastbootResult -arguments @('-s', $serial, 'getvar', $name)
    $pattern = '(?m)' + [regex]::Escape($name) + ':\s*(0x[0-9a-fA-F]+|[a-zA-Z0-9_\-]+)'
    $match = [regex]::Match($answer, $pattern)
    if (!$match.Success) { throw "fastboot did not report $name" }
    return $match.Groups[1].Value
}
$product = GetVar 'product'
$unlocked = GetVar 'unlocked'
$slot = GetVar 'current-slot'
if ($product -ne 'H8416') { throw "Connected $product, not the intended H8416." }
if ($unlocked -notin @('yes','true','1')) { throw 'Bootloader is not unlocked.' }
if ($slot -ne $activeSlot) { throw "Slot $slot is active; this bundle protects slot $activeSlot." }
function PartitionSize([string]$name) {
    $value = GetVar "partition-size:$name"
    if ($value -match '^0x') { return [Convert]::ToInt64($value.Substring(2),16) }
    return [long]$value
}
$bootCapacity = PartitionSize $bootPartition
$systemCapacity = PartitionSize $systemPartition
$userdataCapacity = PartitionSize 'userdata'
$installerSize = (Get-Item (Join-Path $dir 'installer-boot.img')).Length
$tesseraBootSize = (Get-Item (Join-Path $dir 'tessera-boot.img')).Length
$systemSize = (Get-Item (Join-Path $dir 'system-source.img')).Length
if ($bootCapacity -lt [math]::Max($installerSize,$tesseraBootSize)) {
    throw 'Boot image exceeds the measured inactive boot partition.'
}
if ($systemCapacity -lt $systemSize) { throw 'System image exceeds the inactive system partition.' }
if ($userdataCapacity -lt (1GB)) { throw 'Unexpectedly small userdata partition.' }
Write-Output "Xperia XZ3 ${product}: bootloader unlocked, active slot $slot."
Write-Output "Inactive ${bootPartition}: $bootCapacity bytes; ${systemPartition}: $systemCapacity bytes."
Write-Output "userdata: $userdataCapacity bytes; Btrfs will replace its ext4 content."

if (!$Install -and !$TestSystem -and !$Complete) {
    Write-Output 'READ-ONLY PREFLIGHT PASSED. No device changes made.'
    exit 0
}

if ($Install) {
    Write-Output "This operation erases ALL Android userdata. The partition contents cannot be restored by rebooting to slot $activeSlot."
    $first = Read-Host "Type the exact fastboot serial $serial"
    $second = Read-Host 'Type ERASE USERDATA FOR TESSERA to authorize destructive Btrfs installation'
    if ($first -cne $serial -or $second -cne 'ERASE USERDATA FOR TESSERA') {
        throw 'Installation cancelled without changing the phone.'
    }
    Write-Output "Staging the sealed system SquashFS onto inactive ${systemPartition}..."
    Write-Output (FastbootResult -arguments @('-s',$serial,'flash',$systemPartition,(Join-Path $dir 'system-source.img')))
    Write-Output "Temporarily booting the Btrfs installer with its exact userdata/${systemPartition} command line..."
    Write-Output (FastbootResult -arguments @('-s',$serial,'boot',(Join-Path $dir 'installer-boot.img')))
    Write-Output 'Installer RAM boot submitted. Do NOT assume installation succeeded until boot output and Btrfs volume are checked.'
    exit 0
}

if ($TestSystem) {
    Write-Output 'Temporarily testing the Tessera system boot; no partition will be flashed.'
    $confirm = Read-Host "Type $serial to boot Tessera from the existing internal Btrfs volume"
    if ($confirm -cne $serial) { throw 'Temporary boot cancelled.' }
    Write-Output (FastbootResult -arguments @('-s',$serial,'boot',(Join-Path $dir 'tessera-boot.img')))
    exit 0
}

if ($Complete) {
    Write-Output 'This is the final persistent boot switch; it must follow a successful Tessera install and RAM boot.'
    $confirm = Read-Host "Type TESSERA VERIFIED $serial after verifying the running Tessera system"
    if ($confirm -cne "TESSERA VERIFIED $serial") { throw 'Boot switch cancelled.' }
    Write-Output (FastbootResult -arguments @('-s',$serial,'flash',$bootPartition,(Join-Path $dir 'tessera-boot.img')))
    Write-Output (FastbootResult -arguments @('-s',$serial,'set_active',$targetSlot))
    Write-Output "Tessera boot image installed to ${bootPartition}; $targetSlot is now the active slot."
}
