param(
    [string]$InstallDirectory,
    [ValidateRange(1024,65535)][int]$Port = 8080,
    [string]$ChannelUrl = 'https://raw.githubusercontent.com/Thienry18/PortalAkademikGajahMada-Releases/main/stable.json',
    [switch]$NoAutoUpdate,
    [switch]$TestMode
)
$ErrorActionPreference = 'Stop'
if (!$InstallDirectory) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('UserProfile') }
    $InstallDirectory = Join-Path $base 'PortalAkademik'
}
$installPath = [IO.Path]::GetFullPath($InstallDirectory)
if ($installPath -eq [IO.Path]::GetPathRoot($installPath)) { throw 'Use a dedicated installation directory.' }
if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Update-Portal.ps1'))) { throw 'Extract the complete installation package first.' }
if (!$NoAutoUpdate -and $env:OS -ne 'Windows_NT') { throw 'Automatic scheduling currently supports Windows. On PowerShell 7/Linux use -NoAutoUpdate and configure a user timer separately.' }
if ((Test-Path -LiteralPath $installPath) -and ((Get-Item -LiteralPath $installPath).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Installation directory must not be a symbolic link.' }
New-Item -ItemType Directory -Force -Path $installPath | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$hash = [Security.Cryptography.SHA256]::Create()
try { $suffix = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($installPath.ToLowerInvariant()))) -replace '-', '').Substring(0,12).ToLowerInvariant() }
finally { $hash.Dispose() }
$settingsPath = Join-Path $installPath 'updater-settings.json'
if (!(Test-Path -LiteralPath $settingsPath)) {
    $settings = @{schemaVersion=1;channelUrl=$ChannelUrl;projectName=('portal-client-'+$suffix);port=$Port;intervalMinutes=5}
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json), $utf8)
} else {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($settings.channelUrl -ne $ChannelUrl) { throw 'Existing installation uses a different channel; settings were retained.' }
    $Port = $settings.port
}
function New-Secret {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}
$envPath = Join-Path $installPath '.env'
if (!(Test-Path -LiteralPath $envPath)) {
    $lines = @(
        ('APP_PORT=' + $Port)
        ('DB_PASSWORD=' + (New-Secret))
        ('DB_ROOT_PASSWORD=' + (New-Secret))
        ('JWT_SECRET=' + (New-Secret))
        'SEED_DEMO_DATA=true'
    )
    [IO.File]::WriteAllText($envPath, ($lines -join "`n")+"`n", $utf8)
}
foreach ($name in @('Update-Portal.ps1','Uninstall-Portal.ps1')) {
    $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $name))
    $target = Join-Path $installPath $name
    if ($source -ne $target) { Copy-Item -LiteralPath $source -Destination $target -Force }
}
& (Join-Path $installPath 'Update-Portal.ps1') -InstallDirectory $installPath -TestMode:$TestMode
if ($LASTEXITCODE -ne 0) { throw 'Initial application installation failed; automatic updates were not enabled.' }
if (!$NoAutoUpdate) {
    $taskName = 'PortalAkademik-Update-' + $suffix
    $taskUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installPath 'Update-Portal.ps1') + '" -InstallDirectory "' + $installPath + '"')
    $periodic = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($periodic,$logon) -Principal $principal -Settings $taskSettings -Description 'Check the public Portal Akademik stable channel every five minutes and deploy verified releases.' -Force | Out-Null
    Write-Output ('Automatic updates enabled: ' + $taskName + ' (every five minutes while signed in).')
} else { Write-Output 'Installed without a scheduled task (-NoAutoUpdate).' }
Write-Output ('Application: http://127.0.0.1:' + $Port)
Write-Output ('Installation directory: ' + $installPath)
