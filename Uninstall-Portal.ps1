param([string]$InstallDirectory = $PSScriptRoot, [switch]$StopApplication)
$ErrorActionPreference = 'Stop'
$installPath = [IO.Path]::GetFullPath($InstallDirectory)
$settings = Get-Content -LiteralPath (Join-Path $installPath 'updater-settings.json') -Raw | ConvertFrom-Json
if ($settings.projectName -notmatch '^portal-client-([a-f0-9]{12})$') { throw 'Invalid installation identity.' }
$taskName = 'PortalAkademik-Update-' + $Matches[1]
if ($env:OS -eq 'Windows_NT' -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
if ($StopApplication) {
    $state = Get-Content -LiteralPath (Join-Path $installPath 'state.json') -Raw | ConvertFrom-Json
    if ($state.release.version -notmatch '^[a-f0-9]{40}$') { throw 'Invalid installed release.' }
    $images = Join-Path $installPath ('releases/' + $state.release.version + '/images.env')
    & docker compose --project-directory $installPath --env-file (Join-Path $installPath '.env') --env-file $images -p $settings.projectName -f (Join-Path $installPath 'compose.yaml') down
    if ($LASTEXITCODE -ne 0) { throw 'Stopping application failed.' }
}
Write-Output 'Automatic updates disabled. Installation files, database, and uploads are retained.'
