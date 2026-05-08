<#
.SYNOPSIS
    Get-ArtifactFeeds.ps1
    Inventario de Azure Artifacts Feeds (NuGet, npm, Maven, etc.)
    en Azure DevOps Server OnPrem.

.DESCRIPTION
    Consulta las APIs REST de Azure DevOps para obtener:
      1. Feeds a nivel de organizacion (collection) y proyecto
      2. Paquetes por tipo de protocolo (NuGet, npm, Maven, Universal)
      3. Upstream Sources configuradas en cada feed
      4. Views de cada feed
      5. Estadisticas: total de paquetes, versiones, tamanio aproximado

    Genera CSV y JSON con los resultados para planificar la migracion.

.PARAMETER AdoBaseUrl
    URL base de la collection. Lee $env:ADO_BASE (desde .env).

.PARAMETER ProjectFilter
    Filtro por nombre de proyecto (wildcard). Default: * (todos)

.PARAMETER TeamProject
    Nombre exacto de un unico Team Project a auditar.

.PARAMETER OutputDir
    Directorio de salida. Default: .\artifacts-inventory

.PARAMETER PatToken
    PAT de ADO Server. Lee $env:ADO_PAT.

.PARAMETER ApiVersion
    Version de la API REST. Default: 5.0

.PARAMETER IncludeVersions
    Si se activa, descarga todas las versiones de cada paquete (puede ser lento).

.PARAMETER EnvFile
    Ruta al .env. Default: ../.env

.EXAMPLE
    # Inventario de todos los feeds
    .\Get-ArtifactFeeds.ps1

.EXAMPLE
    # Solo un proyecto
    .\Get-ArtifactFeeds.ps1 -TeamProject "TPBCRComercial"

.EXAMPLE
    # Con detalle de versiones
    .\Get-ArtifactFeeds.ps1 -TeamProject "TPBCRComercial" -IncludeVersions
#>

[CmdletBinding()]
param(
    [string]$AdoBaseUrl,
    [string]$ProjectFilter = "*",
    [string]$TeamProject,
    [string]$OutputDir = ".\artifacts-inventory",
    [string]$PatToken,
    [string]$ApiVersion = "5.0",
    [switch]$IncludeVersions,
    [string]$EnvFile = (Join-Path (Split-Path $PSScriptRoot -Parent) ".env")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ================================================================
# HELPERS
# ================================================================
function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-Content -Path $Path | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($key, $val, "Process")
    }
}
Import-DotEnv -Path $EnvFile

if (-not $AdoBaseUrl) { $AdoBaseUrl = $env:ADO_BASE }
if (-not $PatToken)   { $PatToken   = $env:ADO_PAT  }
if (-not $AdoBaseUrl) { Write-Host "ERROR: Falta AdoBaseUrl (ADO_BASE)." -ForegroundColor Red; exit 1 }

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Gray" }
    }
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Invoke-Ado {
    param([string]$Url, [string]$Method = "GET")
    $params = @{ Uri = $Url; Method = $Method; ContentType = "application/json"; UseBasicParsing = $true }
    $headers = @{}
    if ($PatToken) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PatToken"))
        $headers["Authorization"] = "Basic $b64"
    } else {
        $params["UseDefaultCredentials"] = $true
    }
    $params["Headers"] = $headers
    try { return (Invoke-RestMethod @params) }
    catch {
        $msg = $_.Exception.Message
        return [PSCustomObject]@{ _error = $true; _message = $msg }
    }
}

function Test-IsErr { param($r) if ($null -eq $r) { return $true }; if ($r.PSObject.Properties.Match('_error').Count -gt 0) { return [bool]$r._error }; return $false }
function Get-ErrMsg { param($r) if ($null -eq $r) { return "null" }; if ($r.PSObject.Properties.Match('_message').Count -gt 0) { return $r._message }; return "unknown" }

# ================================================================
# FEED INVENTORY
# ================================================================
function Get-FeedsForScope {
    param([string]$BaseUrl, [string]$ScopeLabel)
    $url = "$BaseUrl/_apis/packaging/feeds?api-version=$ApiVersion"
    $r = Invoke-Ado -Url $url
    if (Test-IsErr $r) {
        Write-Status "ERROR obteniendo feeds ($ScopeLabel): $(Get-ErrMsg $r)" -Level ERROR
        return @()
    }
    $feeds = @()
    if ($r.PSObject.Properties.Match('value').Count -gt 0) { $feeds = $r.value }
    return $feeds
}

function Get-FeedPackages {
    param([string]$FeedUrl, [string]$FeedName, [string]$ProtocolType)
    $url = "$FeedUrl/packages?protocolType=$ProtocolType&`$top=5000&api-version=$ApiVersion"
    $r = Invoke-Ado -Url $url
    if (Test-IsErr $r) { return @() }
    $pkgs = @()
    if ($r.PSObject.Properties.Match('value').Count -gt 0) { $pkgs = $r.value }
    return $pkgs
}

function Get-PackageVersions {
    param([string]$FeedUrl, [string]$PackageId)
    $url = "$FeedUrl/packages/$PackageId/versions?api-version=$ApiVersion"
    $r = Invoke-Ado -Url $url
    if (Test-IsErr $r) { return @() }
    if ($r.PSObject.Properties.Match('value').Count -gt 0) { return $r.value }
    return @()
}

# ================================================================
# MAIN
# ================================================================
$_toolName    = "Get-ArtifactFeeds"
$_toolVersion = "1.0.0"
$_toolUpdate  = "2025-05-08"

Write-Host ""
Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Magenta
Write-Host "  │                                                          │" -ForegroundColor Magenta
Write-Host "  │   ■ ■  $_toolName  v$_toolVersion                       │" -ForegroundColor Magenta
Write-Host "  │        Last update: $_toolUpdate                        │" -ForegroundColor Magenta
Write-Host "  │        Azure Artifacts Feed Inventory                   │" -ForegroundColor Magenta
Write-Host "  │                                                          │" -ForegroundColor Magenta
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Collection : $AdoBaseUrl" -ForegroundColor Cyan
Write-Host "  Filtro     : $(if ($TeamProject) { $TeamProject } else { $ProjectFilter })" -ForegroundColor Cyan
Write-Host "  Versiones  : $(if ($IncludeVersions) { 'SI' } else { 'NO' })" -ForegroundColor Cyan
Write-Host ""

$allFeeds = @()
$allPackages = @()
$protocols = @("NuGet", "Npm", "Maven", "Universal")

# --- Organization-scoped feeds ---
Write-Status "Consultando feeds a nivel de Collection (org-scoped)..." -Level INFO
$orgFeeds = Get-FeedsForScope -BaseUrl $AdoBaseUrl -ScopeLabel "Collection"
Write-Status "Feeds org-scoped encontrados: $($orgFeeds.Count)" -Level OK

foreach ($feed in $orgFeeds) {
    $feedName = $feed.name
    $feedId   = $feed.id
    $feedUrl  = "$AdoBaseUrl/_apis/packaging/feeds/$feedId"

    # Upstream sources
    $upstreams = @()
    if ($feed.PSObject.Properties.Match('upstreamSources').Count -gt 0 -and $feed.upstreamSources) {
        $upstreams = @($feed.upstreamSources)
    }
    $upstreamNames = ($upstreams | ForEach-Object { $_.name }) -join ";"

    $feedInfo = [PSCustomObject]@{
        Scope          = "Organization"
        Project        = ""
        FeedName       = $feedName
        FeedId         = $feedId
        TotalPackages  = 0
        NuGetCount     = 0
        NpmCount       = 0
        MavenCount     = 0
        UniversalCount = 0
        UpstreamSources = $upstreamNames
        UpstreamCount  = $upstreams.Count
        Url            = $feed.url
    }

    Write-Status "  Feed '$feedName' (org-scoped) — upstreams: $($upstreams.Count)" -Level INFO

    foreach ($proto in $protocols) {
        $pkgs = Get-FeedPackages -FeedUrl $feedUrl -FeedName $feedName -ProtocolType $proto
        $count = $pkgs.Count
        switch ($proto) {
            "NuGet"     { $feedInfo.NuGetCount     = $count }
            "Npm"       { $feedInfo.NpmCount       = $count }
            "Maven"     { $feedInfo.MavenCount     = $count }
            "Universal" { $feedInfo.UniversalCount = $count }
        }
        $feedInfo.TotalPackages += $count

        if ($count -gt 0) {
            Write-Status "    $proto : $count paquetes" -Level INFO
        }

        foreach ($pkg in $pkgs) {
            $latestVer = ""
            if ($pkg.PSObject.Properties.Match('versions').Count -gt 0 -and $pkg.versions.Count -gt 0) {
                $latestVer = $pkg.versions[0].version
            }
            $pkgEntry = [PSCustomObject]@{
                Scope        = "Organization"
                Project      = ""
                FeedName     = $feedName
                FeedId       = $feedId
                Protocol     = $proto
                PackageName  = $pkg.name
                PackageId    = $pkg.id
                LatestVersion = $latestVer
                VersionCount = if ($pkg.PSObject.Properties.Match('versions').Count -gt 0) { $pkg.versions.Count } else { 0 }
            }

            if ($IncludeVersions) {
                $versions = Get-PackageVersions -FeedUrl $feedUrl -PackageId $pkg.id
                $pkgEntry | Add-Member -MemberType NoteProperty -Name "AllVersions" -Value (($versions | ForEach-Object { $_.version }) -join ";")
                $pkgEntry.VersionCount = $versions.Count
            }

            $allPackages += $pkgEntry
        }
    }

    $allFeeds += $feedInfo
}

# --- Project-scoped feeds ---
Write-Status "Consultando proyectos..." -Level INFO
$projUrl = "$AdoBaseUrl/_apis/projects?`$top=500&api-version=$ApiVersion"
$projResp = Invoke-Ado -Url $projUrl
$projects = @()
if (-not (Test-IsErr $projResp) -and $projResp.PSObject.Properties.Match('value').Count -gt 0) {
    $projects = $projResp.value
}

if ($TeamProject) {
    $projects = @($projects | Where-Object { $_.name -eq $TeamProject })
} elseif ($ProjectFilter -ne "*") {
    $projects = @($projects | Where-Object { $_.name -like $ProjectFilter })
}

Write-Status "Proyectos a revisar: $($projects.Count)" -Level OK

foreach ($proj in $projects) {
    $projName = $proj.name
    Write-Status "Proyecto: $projName" -Level INFO

    $projFeeds = Get-FeedsForScope -BaseUrl "$AdoBaseUrl/$projName" -ScopeLabel $projName
    if ($projFeeds.Count -eq 0) {
        Write-Status "  Sin feeds project-scoped" -Level INFO
        continue
    }
    Write-Status "  Feeds project-scoped: $($projFeeds.Count)" -Level OK

    foreach ($feed in $projFeeds) {
        $feedName = $feed.name
        $feedId   = $feed.id
        $feedUrl  = "$AdoBaseUrl/_apis/packaging/feeds/$feedId"

        $upstreams = @()
        if ($feed.PSObject.Properties.Match('upstreamSources').Count -gt 0 -and $feed.upstreamSources) {
            $upstreams = @($feed.upstreamSources)
        }
        $upstreamNames = ($upstreams | ForEach-Object { $_.name }) -join ";"

        $feedInfo = [PSCustomObject]@{
            Scope          = "Project"
            Project        = $projName
            FeedName       = $feedName
            FeedId         = $feedId
            TotalPackages  = 0
            NuGetCount     = 0
            NpmCount       = 0
            MavenCount     = 0
            UniversalCount = 0
            UpstreamSources = $upstreamNames
            UpstreamCount  = $upstreams.Count
            Url            = $feed.url
        }

        Write-Status "  Feed '$feedName' (project: $projName) — upstreams: $($upstreams.Count)" -Level INFO

        foreach ($proto in $protocols) {
            $pkgs = Get-FeedPackages -FeedUrl $feedUrl -FeedName $feedName -ProtocolType $proto
            $count = $pkgs.Count
            switch ($proto) {
                "NuGet"     { $feedInfo.NuGetCount     = $count }
                "Npm"       { $feedInfo.NpmCount       = $count }
                "Maven"     { $feedInfo.MavenCount     = $count }
                "Universal" { $feedInfo.UniversalCount = $count }
            }
            $feedInfo.TotalPackages += $count

            if ($count -gt 0) {
                Write-Status "    $proto : $count paquetes" -Level INFO
            }

            foreach ($pkg in $pkgs) {
                $latestVer = ""
                if ($pkg.PSObject.Properties.Match('versions').Count -gt 0 -and $pkg.versions.Count -gt 0) {
                    $latestVer = $pkg.versions[0].version
                }
                $pkgEntry = [PSCustomObject]@{
                    Scope        = "Project"
                    Project      = $projName
                    FeedName     = $feedName
                    FeedId       = $feedId
                    Protocol     = $proto
                    PackageName  = $pkg.name
                    PackageId    = $pkg.id
                    LatestVersion = $latestVer
                    VersionCount = if ($pkg.PSObject.Properties.Match('versions').Count -gt 0) { $pkg.versions.Count } else { 0 }
                }

                if ($IncludeVersions) {
                    $versions = Get-PackageVersions -FeedUrl $feedUrl -PackageId $pkg.id
                    $pkgEntry | Add-Member -MemberType NoteProperty -Name "AllVersions" -Value (($versions | ForEach-Object { $_.version }) -join ";")
                    $pkgEntry.VersionCount = $versions.Count
                }

                $allPackages += $pkgEntry
            }
        }

        $allFeeds += $feedInfo
    }
}

# ================================================================
# OUTPUTS
# ================================================================
$ts = Get-Date -Format "yyyyMMdd_HHmmss"

# CSV feeds
$feedCsvPath = Join-Path $OutputDir "artifact_feeds_$ts.csv"
$allFeeds | Export-Csv -Path $feedCsvPath -NoTypeInformation -Encoding UTF8
Write-Status "Feeds CSV: $feedCsvPath ($($allFeeds.Count) feeds)" -Level OK

# CSV packages
$pkgCsvPath = Join-Path $OutputDir "artifact_packages_$ts.csv"
$allPackages | Export-Csv -Path $pkgCsvPath -NoTypeInformation -Encoding UTF8
Write-Status "Packages CSV: $pkgCsvPath ($($allPackages.Count) paquetes)" -Level OK

# JSON completo
$jsonPath = Join-Path $OutputDir "artifact_inventory_$ts.json"
@{
    timestamp = (Get-Date).ToString("o")
    collection = $AdoBaseUrl
    feeds = $allFeeds
    packages = $allPackages
} | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Status "JSON: $jsonPath" -Level OK

# ================================================================
# RESUMEN
# ================================================================
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  RESUMEN DE INVENTARIO                                  ║" -ForegroundColor Green
Write-Host "  ╠══════════════════════════════════════════════════════════╣" -ForegroundColor Green
$totalPkgs = ($allFeeds | Measure-Object -Property TotalPackages -Sum).Sum
$totalNuget = ($allFeeds | Measure-Object -Property NuGetCount -Sum).Sum
$totalNpm = ($allFeeds | Measure-Object -Property NpmCount -Sum).Sum
$totalMaven = ($allFeeds | Measure-Object -Property MavenCount -Sum).Sum
Write-Host "  ║  Feeds totales    : $($allFeeds.Count.ToString().PadLeft(6))                           ║" -ForegroundColor Green
Write-Host "  ║    Org-scoped     : $(($allFeeds | Where-Object { $_.Scope -eq 'Organization' }).Count.ToString().PadLeft(6))                           ║" -ForegroundColor Green
Write-Host "  ║    Project-scoped : $(($allFeeds | Where-Object { $_.Scope -eq 'Project' }).Count.ToString().PadLeft(6))                           ║" -ForegroundColor Green
Write-Host "  ║  Paquetes totales : $($totalPkgs.ToString().PadLeft(6))                           ║" -ForegroundColor Green
Write-Host "  ║    NuGet          : $($totalNuget.ToString().PadLeft(6))                           ║" -ForegroundColor Green
Write-Host "  ║    npm            : $($totalNpm.ToString().PadLeft(6))                           ║" -ForegroundColor Green
Write-Host "  ║    Maven          : $($totalMaven.ToString().PadLeft(6))                           ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
