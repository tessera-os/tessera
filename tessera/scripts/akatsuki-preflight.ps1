# Xperia XZ3 H8416/H9436/H9493: read-only fastboot preflight.
# -BootOnce offers a supervised RAM-only fastboot boot; NO flash/erase/format.
param([switch] $BootOnce)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$directory = Split-Path -Parent $MyInvocation.MyCommand.Path
$image = Join-Path $directory 'boot-test-ufs-disabled.img'
$checksums = Join-Path $directory 'SHA256SUMS'
$fastboot = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\fastboot.exe'
foreach ($path in @($image, $checksums, $fastboot)) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required file: $path"
    }
}

Write-Output 'Checking the XZ3 boot-test files...'
foreach ($entry in (Get-Content -LiteralPath $checksums)) {
    if ($entry -notmatch '^([0-9a-f]{64})  (.+)$') {
        throw "Malformed SHA256SUMS entry: $entry"
    }
    $want = $Matches[1]
    $name = $Matches[2]
    $file = Join-Path $directory $name
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing archive member: $name"
    }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $want) {
        throw "Archive member checksum mismatch: $name"
    }
}
Write-Output 'All package checksums match.'

$devices = @(& $fastboot devices -l | Where-Object { $_ -match '\bfastboot\b' })
if ($devices.Count -ne 1) {
    throw "Expected exactly one fastboot device, found $($devices.Count)."
}
$serial = ($devices[0] -split '\s+')[0]
function Read-FastbootVar([string]$name) {
    $raw = (& $fastboot -s $serial getvar $name 2>&1 | Out-String)
    $escaped = [regex]::Escape($name)
    $match = [regex]::Match($raw, '(?m)' + $escaped + ':\s*(0x[0-9a-fA-F]+|[a-zA-Z0-9_\-]+)')
    if (!$match.Success) { throw "Cannot read fastboot variable: $name" }
    return $match.Groups[1].Value
}

$model = Read-FastbootVar 'product'
$unlocked = Read-FastbootVar 'unlocked'
$slot = Read-FastbootVar 'current-slot'
if ($model -notin @('H8416', 'H9436', 'H9493', 'akatsuki')) {
    throw "Wrong model '$model': this boot image targets Xperia XZ3 only."
}
if ($unlocked -notin @('yes', 'true', '1')) {
    throw 'Bootloader unlock has not been confirmed. No changes made.'
}
if ($slot -notin @('a', 'b')) {
    throw 'Active A/B boot slot not reported.'
}
$capacityHex = Read-FastbootVar "partition-size:boot_$slot"
$capacity = [Convert]::ToInt64($capacityHex.Replace('0x', ''), 16)
$size = (Get-Item -LiteralPath $image).Length
if ($size -gt $capacity) {
    throw "Boot image ($size bytes) exceeds the reported boot partition ($capacity bytes)."
}
Write-Output "Device: $model; unlocked: $unlocked; slot: $slot."
Write-Output "Boot partition: $capacity bytes; temporary image: $size bytes."
Write-Output 'Both UFS nodes AND the UFS kernel driver are disabled in this image.'
Write-Output 'OLED panel, DTBO and bootloader support have not been verified on this XZ3.'

if (!$BootOnce) {
    Write-Output 'READ-ONLY XZ3 FASTBOOT PREFLIGHT PASSED. No phone changes made.'
    exit 0
}

Write-Output 'Temporary RAM boot can hang. It will not flash a partition or install Tessera.'
$confirmed = Read-Host "Type the phone serial $serial to attempt a temporary boot"
if ($confirmed -cne $serial) {
    throw 'Confirmation did not match. No boot attempted.'
}
& $fastboot -s $serial boot $image
if ($LASTEXITCODE -ne 0) {
    throw "Fastboot RAM boot failed with code $LASTEXITCODE."
}