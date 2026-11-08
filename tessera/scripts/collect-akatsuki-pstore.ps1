# Sony Xperia XZ3 (akatsuki) - read-only ADB kernel crash log collector.
# Does not reboot, unlock, flash, format, mount, or write to the phone.
# Run from a Windows PowerShell terminal when recovery/Android ADB is online.
param(
    [string]$Destination = (Join-Path (Join-Path $env:USERPROFILE 'Downloads')
        ('Tessera-XZ3-bootlogs-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (!(Test-Path -LiteralPath $adb -PathType Leaf)) { throw "ADB missing: $adb" }

# All ADB commands used here are read-only. stdout/stderr are captured
# separately to avoid Windows PowerShell 5.1 interpreting stderr as an error.
function Invoke-AdbRead([string[]]$Arguments, [int]$TimeoutSeconds = 25) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adb
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + $_.Replace('"','\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (!$proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch {}
        throw "Timed out while collecting ADB diagnostics"
    }
    return [pscustomobject]@{
        Code = $proc.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

$devices = Invoke-AdbRead @('devices', '-l')
$lines = @($devices.Stdout -split "`r?`n" | Where-Object {
    $_ -match '^\S+\s+(recovery|device|sideload)\b'
})
if ($lines.Count -ne 1) {
    throw ('No single authorized Android/recovery ADB device is available. ' +
        'Fastboot and Sony S1 flash mode cannot expose /sys/fs/pstore.')
}
$serial = ($lines[0] -split '\s+')[0]
if ($lines[0] -match '\bsideload\b') {
    throw 'Sideload-only ADB does not provide a shell; enable ADB in recovery.'
}

function Read-Phone([string]$Command) {
    return Invoke-AdbRead @('-s', $serial, 'shell', $Command)
}

$model = Read-Phone 'getprop ro.product.device'
$hardware = Read-Phone 'getprop ro.boot.hardware'
$product = Read-Phone 'getprop ro.product.model'
if (($model.Stdout -notmatch '(?i)akatsuki|H8416|H9436|H9493') -and
    ($product.Stdout -notmatch '(?i)XZ3|H8416|H9436|H9493')) {
    throw "ADB device has not been verified as an Xperia XZ3: $($model.Stdout.Trim())"
}

New-Item -Path $Destination -ItemType Directory -Force | Out-Null
$summary = New-Object 'System.Collections.Generic.List[string]'
$summary.Add('Tessera Xperia XZ3 read-only ADB crash log capture')
$summary.Add('Timestamp: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'))
$summary.Add('Device model: ' + $product.Stdout.Trim())
$summary.Add('Device codename: ' + $model.Stdout.Trim())
$summary.Add('Hardware: ' + $hardware.Stdout.Trim())

foreach ($record in @(
    @('kernel-cmdline.txt', 'cat /proc/cmdline'),
    @('kernel-version.txt', 'cat /proc/version'),
    @('bootmode.txt', 'getprop ro.bootmode'),
    @('recovery-dmesg.txt', 'dmesg')
)) {
    $response = Read-Phone $record[1]
    if ($response.Code -eq 0 -and $response.Stdout.Trim().Length -gt 0) {
        [IO.File]::WriteAllText((Join-Path $Destination $record[0]),
            $response.Stdout, [Text.UTF8Encoding]::new($false))
        $summary.Add('Saved ' + $record[0])
    } else {
        $summary.Add('Not available ' + $record[0] + ': ' + $response.Stderr.Trim())
    }
}

$pstore = Read-Phone 'ls -1 /sys/fs/pstore'
if ($pstore.Code -eq 0) {
    $names = @($pstore.Stdout -split "`r?`n" | Where-Object {
        $_ -match '^(console|dmesg|pmsg|ftrace)-ramoops(?:-[0-9]+)?$'
    })
    foreach ($name in $names) {
        $response = Read-Phone ('cat /sys/fs/pstore/' + $name)
        if ($response.Code -eq 0 -and $response.Stdout.Length -gt 0) {
            [IO.File]::WriteAllText((Join-Path $Destination ($name + '.txt')),
                $response.Stdout, [Text.UTF8Encoding]::new($false))
            $summary.Add('Saved crash log ' + $name)
        } else {
            $summary.Add('Could not read ' + $name + ': ' + $response.Stderr.Trim())
        }
    }
    if ($names.Count -eq 0) { $summary.Add('Recovery reports no ramoops records') }
} else {
    $summary.Add('pstore not readable: ' + $pstore.Stderr.Trim())
}

$summary.Add('Phone storage was not modified.')
$summaryText = ($summary -join "`r`n") + "`r`n"
[IO.File]::WriteAllText((Join-Path $Destination 'SUMMARY.txt'),
    $summaryText, [Text.UTF8Encoding]::new($false))
Write-Output $summaryText
Write-Output ('Results saved to: ' + $Destination)