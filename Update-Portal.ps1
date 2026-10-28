param(
    [string]$InstallDirectory,
    [switch]$TestMode,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (!$InstallDirectory) { $InstallDirectory = $PSScriptRoot }
$installPath = [IO.Path]::GetFullPath($InstallDirectory)
$settingsPath = Join-Path $installPath 'updater-settings.json'
$statePath = Join-Path $installPath 'state.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$lock = $null
$settings = $null

function Write-UpdateLog([string]$Message) {
    $line = [DateTime]::UtcNow.ToString('o') + ' ' + $Message
    Write-Output $line
    $logPath = Join-Path $installPath 'updater.log'
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 2MB) {
        Move-Item -LiteralPath $logPath -Destination ($logPath + '.previous') -Force
    }
    [IO.File]::AppendAllText($logPath, $line + "`n", $utf8)
}
function Write-JsonAtomic([string]$Path, $Value) {
    [IO.File]::WriteAllText(($Path + '.tmp'), ($Value | ConvertTo-Json -Depth 12), $utf8)
    Move-Item -LiteralPath ($Path + '.tmp') -Destination $Path -Force
}
function Assert-DownloadUri([string]$Address) {
    $uri = [Uri]$Address
    if ($TestMode -and $uri.IsFile) { return }
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'raw.githubusercontent.com' -or !$uri.AbsolutePath.StartsWith('/Thienry18/PortalAkademikGajahMada-Releases/')) {
        throw ('Only the configured public HTTPS distribution repository is trusted (scheme=' + $uri.Scheme + '; test=' + [bool]$TestMode + ').')
    }
}
function Get-Download([string]$Address, [string]$Destination) {
    Assert-DownloadUri $Address
    if ($TestMode -and ([Uri]$Address).IsFile) { Copy-Item -LiteralPath ([Uri]$Address).LocalPath -Destination $Destination }
    else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Address -OutFile $Destination -TimeoutSec 90 -Headers @{'Cache-Control'='no-cache'}
    }
}
function Assert-Release($Release) {
    if ($Release.schemaVersion -ne 1 -or $Release.clientCompatibility -ne 1) { throw 'This release requires a newer installer.' }
    if ($Release.version -notmatch '^[a-f0-9]{40}$' -or [Int64]$Release.sequence -lt 1) { throw 'Invalid release identity.' }
    foreach ($service in @('backend','frontend','gateway')) {
        $reference = [string]$Release.images.$service
        $expected = '^docker\.io/thien18/portal-akademik-' + $service + '@sha256:[a-f0-9]{64}$'
        if ($reference -notmatch $expected -and !($TestMode -and $reference -match '^[a-z0-9./_-]+:[a-zA-Z0-9_.-]+$')) { throw ('Invalid immutable image for ' + $service) }
    }
    if ($Release.images.database -notmatch '^docker\.io/library/mysql@sha256:[a-f0-9]{64}$' -and !($TestMode -and $Release.images.database -eq 'mysql:8.4')) { throw 'Invalid pinned MySQL image.' }
    if ($Release.bootstrap.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid bootstrap checksum.' }
    Assert-DownloadUri $Release.bootstrap.url
}
function Expand-Bootstrap($Release) {
    $zipPath = Join-Path $installPath 'bootstrap.download.zip'
    Get-Download $Release.bootstrap.url $zipPath
    if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Release.bootstrap.sha256) { throw 'Bootstrap checksum mismatch.' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $expected = @('compose.yaml','database/schema.sql')
        $names = @($archive.Entries | ForEach-Object { $_.FullName })
        if ($names.Count -ne 2 -or @($names | Where-Object { $_ -notin $expected }).Count -ne 0 -or @($names | Select-Object -Unique).Count -ne 2) { throw 'Bootstrap must contain exactly the two approved configuration files.' }
        foreach ($entry in $archive.Entries) {
            if ($entry.Length -gt 2MB) { throw 'Bootstrap entry is too large.' }
            $target = [IO.Path]::GetFullPath((Join-Path $installPath $entry.FullName))
            if (!$target.StartsWith($installPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid bootstrap path.' }
            if ($entry.FullName -eq 'database/schema.sql') { New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null }
            # Keep the original schema file and Compose path stable across updates.
            if (!(Test-Path -LiteralPath $target)) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false) }
        }
    } finally { $archive.Dispose() }
}
function New-ImageEnvironment($Release) {
    $releaseDirectory = Join-Path (Join-Path $installPath 'releases') $Release.version
    New-Item -ItemType Directory -Force -Path $releaseDirectory | Out-Null
    $imageFile = Join-Path $releaseDirectory 'images.env'
    $lines = @('PORTAL_RELEASE=' + $Release.version)
    foreach ($service in @('backend','frontend','gateway','database')) { $lines += 'PORTAL_' + $service.ToUpperInvariant() + '_IMAGE=' + $Release.images.$service }
    [IO.File]::WriteAllText($imageFile, ($lines -join "`n") + "`n", $utf8)
    Write-JsonAtomic (Join-Path $releaseDirectory 'manifest.json') $Release
    return $imageFile
}
function Invoke-PortalCompose([string]$ImageFile, [string[]]$Arguments) {
    & docker compose --project-directory $installPath --env-file (Join-Path $installPath '.env') --env-file $ImageFile -p $settings.projectName -f (Join-Path $installPath 'compose.yaml') @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('Compose failed: ' + ($Arguments -join ' ')) }
}
function Test-PortalRelease([string]$ExpectedVersion, [string]$ImageFile) {
    $json = & docker compose --project-directory $installPath --env-file (Join-Path $installPath '.env') --env-file $ImageFile -p $settings.projectName -f (Join-Path $installPath 'compose.yaml') ps --format json
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect deployment.' }
    $containers = @($json | ForEach-Object { if ($_.Trim()) { ConvertFrom-Json $_ } })
    if ($containers.Count -ne 4 -or @($containers | Where-Object { $_.State -ne 'running' -or $_.Health -ne 'healthy' }).Count -ne 0) { throw 'Expected four healthy application services.' }
    $base = 'http://127.0.0.1:' + $settings.port
    $health = Invoke-RestMethod -Uri ($base + '/health') -TimeoutSec 15
    if ($health.database -ne 'connected' -or $health.release -ne $ExpectedVersion) { throw 'The running backend does not match the intended release.' }
    $page = Invoke-WebRequest -UseBasicParsing -Uri ($base + '/') -TimeoutSec 15
    if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'loginForm') { throw 'Frontend check failed.' }
}

try {
    if (!(Test-Path -LiteralPath $settingsPath)) { throw 'Run Install-Portal.ps1 first.' }
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($settings.schemaVersion -ne 1 -or $settings.projectName -notmatch '^portal-client-[a-f0-9]{12}$' -or [int]$settings.port -lt 1024 -or [int]$settings.port -gt 65535) { throw 'Invalid updater settings.' }
    try { $lock = [IO.File]::Open((Join-Path $installPath 'update.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { Write-Output 'Another update is already running; skipped.'; exit 0 }
    $remotePath = Join-Path $installPath 'channel.download.json'
    Get-Download $settings.channelUrl $remotePath
    $release = Get-Content -LiteralPath $remotePath -Raw | ConvertFrom-Json
    Assert-Release $release
    $previous = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
    if ($previous) {
        Assert-Release $previous.release
        if ([Int64]$release.sequence -lt [Int64]$previous.release.sequence) { throw 'An older channel sequence was rejected.' }
        if ($release.images.database -ne $previous.release.images.database) { throw 'Database image changes require a planned manual database upgrade.' }
        if ($release.version -eq $previous.release.version) {
            $imageFile = New-ImageEnvironment $previous.release
            Test-PortalRelease $previous.release.version $imageFile
            Write-UpdateLog ('Already running verified release ' + $release.version)
            exit 0
        }
        $failedPath = Join-Path $installPath 'failed-release.json'
        if (!$Force -and (Test-Path -LiteralPath $failedPath) -and (Get-Content -LiteralPath $failedPath -Raw | ConvertFrom-Json).version -eq $release.version) {
            Write-UpdateLog ('Release previously failed; waiting for a newer version: ' + $release.version)
            exit 0
        }
    }
    & docker info --format '{{.ServerVersion}}' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker is unavailable; the next scheduled check can retry.' }
    if (!$previous) { Expand-Bootstrap $release }
    $imageFile = New-ImageEnvironment $release
    Invoke-PortalCompose $imageFile @('config','--quiet')
    # Pull the complete application release before replacing any service.
    $pull = @('pull','backend','frontend','gateway')
    if (!$previous) { $pull += 'database' }
    if (!$TestMode) { Invoke-PortalCompose $imageFile $pull }
    try {
        if ($previous) { Invoke-PortalCompose $imageFile @('up','-d','--no-build','--pull','never','--no-deps','--wait','--wait-timeout','180','backend','frontend','gateway') }
        else { Invoke-PortalCompose $imageFile @('up','-d','--no-build','--pull','never','--wait','--wait-timeout','240') }
        Test-PortalRelease $release.version $imageFile
        Write-JsonAtomic $statePath @{schemaVersion=1; release=$release; verifiedAt=[DateTime]::UtcNow.ToString('o')}
        Write-UpdateLog ('Activated verified release ' + $release.version)
    } catch {
        $failure = $_
        Write-JsonAtomic (Join-Path $installPath 'failed-release.json') @{version=$release.version;message='Startup or health verification failed';failedAt=[DateTime]::UtcNow.ToString('o')}
        if ($previous) {
            Write-UpdateLog ('New release failed; restoring ' + $previous.release.version)
            $oldImageFile = New-ImageEnvironment $previous.release
            Invoke-PortalCompose $oldImageFile @('up','-d','--no-build','--pull','never','--no-deps','--wait','--wait-timeout','180','backend','frontend','gateway')
            Test-PortalRelease $previous.release.version $oldImageFile
            Write-UpdateLog 'Previous application release restored; database volumes retained.'
        }
        throw $failure
    }
} catch {
    Write-UpdateLog ('Update failed: ' + $_.Exception.Message)
    exit 1
} finally { if ($lock) { $lock.Dispose() } }
