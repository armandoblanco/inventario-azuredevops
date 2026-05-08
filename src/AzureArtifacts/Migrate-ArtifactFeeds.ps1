<#
.SYNOPSIS
    Migrate-ArtifactFeeds.ps1
    Migra Azure Artifacts Feeds (NuGet, npm) desde Azure DevOps Server OnPrem
    hacia Azure DevOps Services (Cloud).

.DESCRIPTION
    Pipeline de migracion en fases con soporte para topologia hub-spoke:
    un feed PRINCIPAL con upstream a registros publicos (nuget.org, npmjs.com)
    y feeds SATELITE que usan el principal como upstream.

    Fases:
      1) Inventario de feeds, paquetes y upstreams en origen
      2) Crear feeds en destino (principal primero, luego satelites)
      3) Configurar upstream sources (principal → publicos, satelites → principal)
      4) Descargar paquetes del origen a staging local
      5) Publicar paquetes al destino (NuGet push / npm publish)

    TOPOLOGIA SOPORTADA:
      Feed Principal (hub)  →  upstream a nuget.org, npmjs.com
      Feed Satelite A       →  upstream al Feed Principal
      Feed Satelite B       →  upstream al Feed Principal

    REQUISITOS:
      - El proyecto destino debe existir.
      - PAT destino con scope: Packaging (Read, Write & Manage)
      - Para npm: Node.js instalado (npm publish)
      - Para NuGet: nuget.exe o dotnet CLI en PATH (opcional, usa REST API si no)

    LIMITACIONES:
      - No migra permisos de feed (readers/contributors) — asignarlos manualmente.
      - Paquetes upstream cacheados no se descargan: se recachearan del publico.
      - Maven/Universal Packages no soportados en esta version.
      - Views (@Release, @Prerelease) se crean pero la promocion debe rehacerse.

.PARAMETER SourceBaseUrl
    URL base de la collection origen. Lee $env:ADO_SOURCE_BASE.

.PARAMETER SourcePat
    PAT del ADO Server origen. Lee $env:ADO_SOURCE_PAT.

.PARAMETER SourceProject
    Proyecto origen (para feeds project-scoped). Puede ser vacio para org-scoped.

.PARAMETER TargetOrgUrl
    URL de la org destino. Lee $env:ADO_TARGET_ORG_URL.

.PARAMETER TargetPat
    PAT de ADO Services destino. Lee $env:ADO_TARGET_PAT.

.PARAMETER TargetProject
    Proyecto destino. Lee $env:ADO_TARGET_PROJECT.

.PARAMETER PrincipalFeed
    Nombre del feed principal (hub) que tiene upstream a internet.
    Los demas feeds se configuran como satelites apuntando a este.

.PARAMETER FeedFilter
    Filtro wildcard por nombre de feed. Default: * (todos). Ej: "BCR*"

.PARAMETER StagingDir
    Directorio temporal para descargar paquetes. Default: .\artifacts-staging

.PARAMETER OutputDir
    Directorio para mappings y logs. Default: .\artifacts-migration

.PARAMETER SkipPackagePush
    Solo crear feeds y configurar upstreams, no migrar paquetes.

.PARAMETER OnlyLatestVersion
    Solo migrar la ultima version de cada paquete (mas rapido).

.PARAMETER PackageTypes
    Tipos de paquete a migrar: NuGet, Npm, All. Default: All

.PARAMETER Execute
    Switch para ejecutar cambios reales. Sin esto, solo inventario/dry-run.

.PARAMETER EnvFile
    Ruta al .env. Default: ../.env

.EXAMPLE
    # PASO 1: Inventario y dry-run
    .\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed"

.EXAMPLE
    # PASO 2: Crear feeds y configurar upstreams (sin paquetes)
    .\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed" -SkipPackagePush -Execute

.EXAMPLE
    # PASO 3: Migracion completa con paquetes
    .\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed" -Execute

.EXAMPLE
    # Solo un feed especifico, ultima version
    .\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed" `
        -FeedFilter "TPBCRComercial_feed" -OnlyLatestVersion -Execute
#>

[CmdletBinding()]
param(
    [string]$SourceBaseUrl,
    [string]$SourcePat,
    [string]$SourceProject,

    [string]$TargetOrgUrl,
    [string]$TargetPat,
    [string]$TargetProject,

    [Parameter(Mandatory=$true)]
    [string]$PrincipalFeed,

    [string]$FeedFilter = "*",
    [string]$StagingDir = ".\artifacts-staging",
    [string]$OutputDir  = ".\artifacts-migration",
    [string]$SourceApiVersion = "5.0",
    [string]$TargetApiVersion = "7.1",
    [string]$PackageTypes = "All",

    [switch]$SkipPackagePush,
    [switch]$OnlyLatestVersion,
    [switch]$Execute,

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

if (-not $SourceBaseUrl) { $SourceBaseUrl = $env:ADO_SOURCE_BASE }
if (-not $SourcePat)     { $SourcePat     = $env:ADO_SOURCE_PAT  }
if (-not $TargetOrgUrl)  { $TargetOrgUrl  = $env:ADO_TARGET_ORG_URL }
if (-not $TargetPat)     { $TargetPat     = $env:ADO_TARGET_PAT  }
if (-not $TargetProject) { $TargetProject = $env:ADO_TARGET_PROJECT }

if (-not $SourceBaseUrl) { $SourceBaseUrl = $env:ADO_BASE }
if (-not $SourcePat)     { $SourcePat     = $env:ADO_PAT  }

if (-not $SourceBaseUrl) { Write-Host "ERROR: Falta SourceBaseUrl (ADO_SOURCE_BASE)." -ForegroundColor Red; exit 1 }
if (-not $TargetOrgUrl)  { Write-Host "ERROR: Falta TargetOrgUrl (ADO_TARGET_ORG_URL)." -ForegroundColor Red; exit 1 }
if (-not $TargetPat)     { Write-Host "ERROR: Falta TargetPat (ADO_TARGET_PAT)." -ForegroundColor Red; exit 1 }
if (-not $SourcePat)     { Write-Host "WARN: ADO_SOURCE_PAT vacio, usando credenciales Windows." -ForegroundColor Yellow }

$TargetOrgUrl = $TargetOrgUrl.TrimEnd('/')
$orgName = ($TargetOrgUrl -split '/')[-1]
$pkgsUrl  = "https://pkgs.dev.azure.com/$orgName"
$feedsUrl = "https://feeds.dev.azure.com/$orgName"

New-Item -ItemType Directory -Path $OutputDir  -Force | Out-Null
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

# Logging
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $OutputDir "migrate_artifacts_$logTimestamp.log"

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "DRY"   { "DarkCyan" }
        default { "Gray" }
    }
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $color
    $line | Out-File -FilePath $logFile -Append -Encoding UTF8
}

function Pretty-Action {
    param([string]$Action, [string]$Detail)
    $prefix = if ($Execute) { "[EXEC]" } else { "[DRY-RUN]" }
    $color  = if ($Execute) { "Green" } else { "DarkCyan" }
    Write-Host "  $prefix $Action : $Detail" -ForegroundColor $color
}

# ================================================================
# REST HELPERS
# ================================================================
function Invoke-Ado {
    param([string]$Url, [string]$Method = "GET", $Body, [string]$ContentType = "application/json")
    $headers = @{}
    $params = @{ Uri = $Url; Method = $Method; ContentType = $ContentType; UseBasicParsing = $true }
    if ($SourcePat) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$SourcePat"))
        $headers["Authorization"] = "Basic $b64"
    } else {
        $params["UseDefaultCredentials"] = $true
    }
    $params["Headers"] = $headers
    if ($Body) { $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 } }
    try { return (Invoke-RestMethod @params) }
    catch {
        $msg = $_.Exception.Message
        try { $msg = ($_ | ConvertFrom-Json).message } catch {}
        return [PSCustomObject]@{ _error = $true; _message = $msg; _status = $_.Exception.Response.StatusCode }
    }
}

function Invoke-Target {
    param([string]$BaseUrl, [string]$Path, [string]$Method = "GET", $Body,
          [string]$ContentType = "application/json", [string]$ApiVer = $TargetApiVersion)
    $sep = if ($Path.Contains("?")) { "&" } else { "?" }
    $url = "$BaseUrl/$Path${sep}api-version=$ApiVer"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$TargetPat"))
    $headers = @{ "Authorization" = "Basic $b64" }
    $params = @{ Uri = $url; Method = $Method; Headers = $headers; ContentType = $ContentType; UseBasicParsing = $true }
    if ($Body) { $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 } }
    try { return (Invoke-RestMethod @params) }
    catch {
        $msg = $_.Exception.Message
        try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json); $msg = $detail.message } catch {}
        return [PSCustomObject]@{ _error = $true; _message = $msg; _status = $_.Exception.Response.StatusCode }
    }
}

function Test-IsErr { param($r) if ($null -eq $r) { return $true }; if ($r.PSObject.Properties.Match('_error').Count -gt 0) { return [bool]$r._error }; return $false }
function Get-ErrMsg { param($r) if ($null -eq $r) { return "null" }; if ($r.PSObject.Properties.Match('_message').Count -gt 0) { return $r._message }; return "unknown" }

function Load-Map {
    param([string]$Path)
    $map = @{}
    if (Test-Path $Path) {
        $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
    return $map
}
function Save-Map { param([hashtable]$Map, [string]$Path) ($Map | ConvertTo-Json -Depth 5) | Out-File -FilePath $Path -Encoding UTF8 }

# Mapping paths
$mapPaths = @{
    Feed    = Join-Path $OutputDir "mapping-feeds.json"
    Package = Join-Path $OutputDir "mapping-packages.json"
}

$script:FeedMap    = Load-Map $mapPaths.Feed
$script:PackageMap = Load-Map $mapPaths.Package

# ================================================================
# PHASE 1: Source Inventory
# ================================================================
function Get-SourceFeeds {
    Write-Status "=== FASE 1: Inventario de Feeds en Origen ===" -Level OK

    $allFeeds = @()

    # Org-scoped feeds
    $url = "$SourceBaseUrl/_apis/packaging/feeds?api-version=$SourceApiVersion"
    $r = Invoke-Ado -Url $url
    if (-not (Test-IsErr $r) -and $r.PSObject.Properties.Match('value').Count -gt 0) {
        foreach ($f in $r.value) {
            $f | Add-Member -MemberType NoteProperty -Name "_scope" -Value "Organization" -Force
            $f | Add-Member -MemberType NoteProperty -Name "_project" -Value "" -Force
            $allFeeds += $f
        }
    }

    # Project-scoped feeds (if SourceProject specified)
    if ($SourceProject) {
        $url = "$SourceBaseUrl/$SourceProject/_apis/packaging/feeds?api-version=$SourceApiVersion"
        $r = Invoke-Ado -Url $url
        if (-not (Test-IsErr $r) -and $r.PSObject.Properties.Match('value').Count -gt 0) {
            foreach ($f in $r.value) {
                $f | Add-Member -MemberType NoteProperty -Name "_scope" -Value "Project" -Force
                $f | Add-Member -MemberType NoteProperty -Name "_project" -Value $SourceProject -Force
                $allFeeds += $f
            }
        }
    }

    # Aplicar filtro
    if ($FeedFilter -ne "*") {
        $allFeeds = @($allFeeds | Where-Object { $_.name -like $FeedFilter })
    }

    Write-Status "Feeds encontrados: $($allFeeds.Count)" -Level OK

    # Enriquecer con conteo de paquetes
    foreach ($feed in $allFeeds) {
        $feedUrl = "$SourceBaseUrl/_apis/packaging/feeds/$($feed.id)"
        $upstreams = @()
        if ($feed.PSObject.Properties.Match('upstreamSources').Count -gt 0 -and $feed.upstreamSources) {
            $upstreams = @($feed.upstreamSources)
        }
        $isPrincipal = ($feed.name -eq $PrincipalFeed)

        $nugetPkgs = @()
        $npmPkgs   = @()
        if ($PackageTypes -in @("All","NuGet")) {
            $r = Invoke-Ado -Url "$feedUrl/packages?protocolType=NuGet&`$top=5000&api-version=$SourceApiVersion"
            if (-not (Test-IsErr $r) -and $r.PSObject.Properties.Match('value').Count -gt 0) { $nugetPkgs = @($r.value) }
        }
        if ($PackageTypes -in @("All","Npm")) {
            $r = Invoke-Ado -Url "$feedUrl/packages?protocolType=Npm&`$top=5000&api-version=$SourceApiVersion"
            if (-not (Test-IsErr $r) -and $r.PSObject.Properties.Match('value').Count -gt 0) { $npmPkgs = @($r.value) }
        }

        $role = if ($isPrincipal) { "PRINCIPAL (hub)" } else { "Satelite" }
        Write-Status "  Feed '$($feed.name)' [$role] — NuGet: $($nugetPkgs.Count), npm: $($npmPkgs.Count), upstreams: $($upstreams.Count)" -Level INFO

        $feed | Add-Member -MemberType NoteProperty -Name "_nugetPackages" -Value $nugetPkgs -Force
        $feed | Add-Member -MemberType NoteProperty -Name "_npmPackages"   -Value $npmPkgs   -Force
        $feed | Add-Member -MemberType NoteProperty -Name "_isPrincipal"   -Value $isPrincipal -Force
    }

    return $allFeeds
}

# ================================================================
# PHASE 2: Create Feeds in Target
# ================================================================
function Get-TargetFeeds {
    $r = Invoke-Target -BaseUrl $feedsUrl -Path "_apis/packaging/feeds"
    if (Test-IsErr $r) { return @() }
    if ($r.PSObject.Properties.Match('value').Count -gt 0) { return @($r.value) }
    return @()
}

function New-TargetFeed {
    param([string]$FeedName, [string]$Description, [string]$Scope, [string]$Project)

    $body = @{
        name = $FeedName
        description = $Description
        hideDeletedPackageVersions = $true
        badgesEnabled = $false
    }

    # Para project-scoped en destino, usar la URL del proyecto
    if ($Scope -eq "Project" -and $TargetProject) {
        $path = "$TargetProject/_apis/packaging/feeds"
        $body["project"] = @{ id = $null } # se resuelve con la URL
        return Invoke-Target -BaseUrl $feedsUrl -Path $path -Method POST -Body $body -ApiVer "7.1-preview.1"
    } else {
        return Invoke-Target -BaseUrl $feedsUrl -Path "_apis/packaging/feeds" -Method POST -Body $body -ApiVer "7.1-preview.1"
    }
}

function Create-TargetFeeds {
    param($SourceFeeds)
    Write-Status "=== FASE 2: Crear Feeds en Destino ===" -Level OK

    # Obtener feeds existentes en destino
    $existingFeeds = Get-TargetFeeds
    $existingNames = @{}
    foreach ($f in $existingFeeds) { $existingNames[$f.name] = $f.id }

    # Orden: principal primero, luego satelites
    $ordered = @($SourceFeeds | Sort-Object { if ($_._isPrincipal) { 0 } else { 1 } })

    $created = 0; $skipped = 0

    foreach ($feed in $ordered) {
        $feedName = $feed.name
        $desc = if ($feed.PSObject.Properties.Match('description').Count -gt 0) { $feed.description } else { "" }
        $role = if ($feed._isPrincipal) { "PRINCIPAL" } else { "Satelite" }

        if ($script:FeedMap.ContainsKey($feedName)) {
            Write-Status "  SKIP: Feed '$feedName' [$role] ya mapeado" -Level INFO
            $skipped++
            continue
        }

        if ($existingNames.ContainsKey($feedName)) {
            $script:FeedMap[$feedName] = "$($existingNames[$feedName])"
            Save-Map $script:FeedMap $mapPaths.Feed
            Write-Status "  EXISTS: Feed '$feedName' [$role] ya existe (id=$($existingNames[$feedName]))" -Level INFO
            $skipped++
            continue
        }

        Pretty-Action "Crear Feed" "'$feedName' [$role] scope=$($feed._scope)"
        if ($Execute) {
            $r = New-TargetFeed -FeedName $feedName -Description $desc -Scope $feed._scope -Project $feed._project
            if (Test-IsErr $r) {
                Write-Status "    ERROR: $(Get-ErrMsg $r)" -Level ERROR
                continue
            }
            $script:FeedMap[$feedName] = "$($r.id)"
            Save-Map $script:FeedMap $mapPaths.Feed
            Write-Status "    OK: Feed '$feedName' creado (id=$($r.id))" -Level OK
            $created++
        }
    }

    Write-Status "Feeds: $created creados, $skipped omitidos" -Level OK
}

# ================================================================
# PHASE 3: Configure Upstream Sources
# ================================================================
function Configure-Upstreams {
    param($SourceFeeds)
    Write-Status "=== FASE 3: Configurar Upstream Sources ===" -Level OK

    # Necesitamos el feed ID del principal en destino
    $principalTargetId = $null
    if ($script:FeedMap.ContainsKey($PrincipalFeed)) {
        $principalTargetId = $script:FeedMap[$PrincipalFeed]
    }

    foreach ($feed in $SourceFeeds) {
        $feedName = $feed.name
        $targetFeedId = $null
        if ($script:FeedMap.ContainsKey($feedName)) {
            $targetFeedId = $script:FeedMap[$feedName]
        }

        if (-not $targetFeedId) {
            Write-Status "  SKIP: Feed '$feedName' sin ID destino (ejecute Fase 2 primero)" -Level WARN
            continue
        }

        $upstreams = @()

        if ($feed._isPrincipal) {
            # Principal → upstream a registros publicos
            $upstreams += @{
                id = [guid]::NewGuid().ToString()
                name = "npmjs"
                protocol = "npm"
                location = "https://registry.npmjs.org/"
                upstreamSourceType = "public"
            }
            $upstreams += @{
                id = [guid]::NewGuid().ToString()
                name = "NuGet Gallery"
                protocol = "nuget"
                location = "https://api.nuget.org/v3/index.json"
                upstreamSourceType = "public"
            }
            $upstreams += @{
                id = [guid]::NewGuid().ToString()
                name = "Maven Central"
                protocol = "Maven"
                location = "https://repo.maven.apache.org/maven2/"
                upstreamSourceType = "public"
            }
            Pretty-Action "Upstream" "Feed '$feedName' [PRINCIPAL] → npmjs + NuGet Gallery + Maven Central"
        } else {
            # Satelite → upstream al principal
            if ($principalTargetId) {
                $upstreams += @{
                    id = [guid]::NewGuid().ToString()
                    name = "$PrincipalFeed"
                    protocol = "nuget"
                    location = "$pkgsUrl/_packaging/$PrincipalFeed/nuget/v3/index.json"
                    upstreamSourceType = "internal"
                }
                $upstreams += @{
                    id = [guid]::NewGuid().ToString()
                    name = "${PrincipalFeed}_npm"
                    protocol = "npm"
                    location = "$pkgsUrl/_packaging/$PrincipalFeed/npm/registry/"
                    upstreamSourceType = "internal"
                }
                Pretty-Action "Upstream" "Feed '$feedName' [Satelite] → $PrincipalFeed (interno)"
            } else {
                # Fallback: si no hay principal, conectar directo a publicos
                $upstreams += @{
                    id = [guid]::NewGuid().ToString()
                    name = "npmjs"
                    protocol = "npm"
                    location = "https://registry.npmjs.org/"
                    upstreamSourceType = "public"
                }
                $upstreams += @{
                    id = [guid]::NewGuid().ToString()
                    name = "NuGet Gallery"
                    protocol = "nuget"
                    location = "https://api.nuget.org/v3/index.json"
                    upstreamSourceType = "public"
                }
                Pretty-Action "Upstream" "Feed '$feedName' → publicos (sin principal disponible)"
            }
        }

        if ($Execute -and $upstreams.Count -gt 0) {
            $body = @{ upstreamSources = $upstreams }
            $r = Invoke-Target -BaseUrl $feedsUrl -Path "_apis/packaging/feeds/$targetFeedId" -Method PATCH -Body $body -ApiVer "7.1-preview.1"
            if (Test-IsErr $r) {
                Write-Status "    ERROR upstream '$feedName': $(Get-ErrMsg $r)" -Level ERROR
            } else {
                Write-Status "    OK: Upstreams configurados para '$feedName'" -Level OK
            }
        }
    }
}

# ================================================================
# PHASE 4: Download Packages from Source
# ================================================================
function Download-SourcePackage {
    param([string]$FeedId, [string]$Protocol, [string]$PackageName, [string]$Version)

    $safeName = $PackageName -replace '[/\\:*?"<>|@]', '_'
    $ext = switch ($Protocol) { "NuGet" { ".nupkg" }; "Npm" { ".tgz" }; default { ".pkg" } }
    $fileName = "${safeName}.${Version}${ext}"
    $outPath  = Join-Path $StagingDir $fileName

    if (Test-Path $outPath) { return $outPath }  # ya descargado

    $encodedName = [Uri]::EscapeDataString($PackageName)
    $encodedVer  = [Uri]::EscapeDataString($Version)

    switch ($Protocol) {
        "NuGet" {
            $url = "$SourceBaseUrl/_apis/packaging/feeds/$FeedId/nuget/packages/$encodedName/versions/$encodedVer/content?api-version=$SourceApiVersion"
        }
        "Npm" {
            $url = "$SourceBaseUrl/_apis/packaging/feeds/$FeedId/npm/packages/$encodedName/versions/$encodedVer/content?api-version=$SourceApiVersion"
        }
        default { return $null }
    }

    $headers = @{}
    $params = @{ Uri = $url; OutFile = $outPath; UseBasicParsing = $true }
    if ($SourcePat) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$SourcePat"))
        $headers["Authorization"] = "Basic $b64"
    } else {
        $params["UseDefaultCredentials"] = $true
    }
    $params["Headers"] = $headers

    try {
        Invoke-WebRequest @params
        return $outPath
    } catch {
        Write-Status "    ERROR descarga $PackageName@$Version : $($_.Exception.Message)" -Level ERROR
        return $null
    }
}

# ================================================================
# PHASE 5: Push Packages to Target
# ================================================================
function Push-NuGetPackage {
    param([string]$FilePath, [string]$FeedName)
    # Intentar con dotnet nuget push, luego nuget.exe, luego REST API
    $feedUrl = "$pkgsUrl/_packaging/$FeedName/nuget/v2"
    $apiKey  = "az"  # Azure DevOps ignora el API key, usa el header

    # Opcion 1: dotnet nuget push
    $dotnetAvailable = Get-Command "dotnet" -ErrorAction SilentlyContinue
    if ($dotnetAvailable) {
        $sourceUrl = "$pkgsUrl/$TargetProject/_packaging/$FeedName/nuget/v3/index.json"
        $result = & dotnet nuget push $FilePath --source $sourceUrl --api-key $apiKey --skip-duplicate 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        # Si falla skip-duplicate, puede ser que ya exista
        if ($result -match 'already exists|conflict|409') { return $true }
    }

    # Opcion 2: nuget.exe
    $nugetAvailable = Get-Command "nuget" -ErrorAction SilentlyContinue
    if ($nugetAvailable) {
        & nuget push $FilePath -Source $feedUrl -ApiKey $apiKey -SkipDuplicate 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
    }

    # Opcion 3: REST API PUT
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$TargetPat"))
    $headers = @{
        "Authorization" = "Basic $b64"
        "X-NuGet-ApiKey" = $TargetPat
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        Invoke-RestMethod -Uri $feedUrl -Method PUT -Headers $headers -Body $bytes `
            -ContentType "application/octet-stream" -UseBasicParsing | Out-Null
        return $true
    } catch {
        if ($_.Exception.Message -match 'already exists|conflict|409') { return $true }
        Write-Status "      ERROR push NuGet: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Push-NpmPackage {
    param([string]$FilePath, [string]$FeedName)
    $registryUrl = "$pkgsUrl/_packaging/$FeedName/npm/registry/"

    # Configurar .npmrc temporal
    $npmrcPath = Join-Path $StagingDir ".npmrc"
    $b64Pat = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($TargetPat))
    $npmrcContent = @"
registry=$registryUrl
; begin auth
//$($pkgsUrl -replace 'https://', '')/_packaging/$FeedName/npm/registry/:username=VssSessionToken
//$($pkgsUrl -replace 'https://', '')/_packaging/$FeedName/npm/registry/:_password=$b64Pat
//$($pkgsUrl -replace 'https://', '')/_packaging/$FeedName/npm/registry/:email=npm@requires.email
//$($pkgsUrl -replace 'https://', '')/_packaging/$FeedName/npm/:username=VssSessionToken
//$($pkgsUrl -replace 'https://', '')/_packaging/$FeedName/npm/:_password=$b64Pat
//$($pkgsUrl -replace 'https://', '')/_packaging/$FeedName/npm/:email=npm@requires.email
always-auth=true
; end auth
"@
    $npmrcContent | Out-File -FilePath $npmrcPath -Encoding UTF8 -Force

    $npmAvailable = Get-Command "npm" -ErrorAction SilentlyContinue
    if ($npmAvailable) {
        $result = & npm publish $FilePath --registry $registryUrl --userconfig $npmrcPath 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        if ("$result" -match 'already exists|EPUBLISHCONFLICT|403|409') { return $true }
        Write-Status "      ERROR push npm: $result" -Level ERROR
    } else {
        Write-Status "      ERROR: npm CLI no disponible. Instale Node.js para publicar paquetes npm." -Level ERROR
    }
    return $false
}

function Migrate-Packages {
    param($SourceFeeds)
    Write-Status "=== FASE 4/5: Descargar y Publicar Paquetes ===" -Level OK

    if ($SkipPackagePush) {
        Write-Status "  Omitido por -SkipPackagePush" -Level WARN
        return
    }

    $totalDown = 0; $totalPush = 0; $totalSkip = 0; $totalErr = 0

    foreach ($feed in $SourceFeeds) {
        $feedName = $feed.name
        $feedId   = $feed.id

        if (-not $script:FeedMap.ContainsKey($feedName)) {
            Write-Status "  SKIP: Feed '$feedName' sin ID destino" -Level WARN
            continue
        }

        # NuGet packages
        if ($PackageTypes -in @("All","NuGet")) {
            foreach ($pkg in @($feed._nugetPackages)) {
                $pkgName = $pkg.name

                # Obtener versiones
                $versions = @()
                if ($OnlyLatestVersion) {
                    if ($pkg.PSObject.Properties.Match('versions').Count -gt 0 -and @($pkg.versions).Count -gt 0) {
                        $versions = @($pkg.versions[0])
                    }
                } else {
                    $vUrl = "$SourceBaseUrl/_apis/packaging/feeds/$feedId/packages/$($pkg.id)/versions?api-version=$SourceApiVersion"
                    $vResp = Invoke-Ado -Url $vUrl
                    if (-not (Test-IsErr $vResp) -and $vResp.PSObject.Properties.Match('value').Count -gt 0) {
                        $versions = @($vResp.value)
                    } elseif ($pkg.PSObject.Properties.Match('versions').Count -gt 0) {
                        $versions = @($pkg.versions)
                    }
                }

                foreach ($ver in $versions) {
                    $verStr = $ver.version
                    $mapKey = "nuget:$pkgName@$verStr"

                    if ($script:PackageMap.ContainsKey($mapKey)) {
                        $totalSkip++
                        continue
                    }

                    Pretty-Action "NuGet" "'$pkgName' v$verStr → feed '$feedName'"
                    if ($Execute) {
                        $file = Download-SourcePackage -FeedId $feedId -Protocol "NuGet" -PackageName $pkgName -Version $verStr
                        if ($file) {
                            $totalDown++
                            $ok = Push-NuGetPackage -FilePath $file -FeedName $feedName
                            if ($ok) {
                                $script:PackageMap[$mapKey] = "OK"
                                Save-Map $script:PackageMap $mapPaths.Package
                                $totalPush++
                            } else { $totalErr++ }
                        } else { $totalErr++ }
                    }
                }
            }
        }

        # npm packages
        if ($PackageTypes -in @("All","Npm")) {
            foreach ($pkg in @($feed._npmPackages)) {
                $pkgName = $pkg.name

                $versions = @()
                if ($OnlyLatestVersion) {
                    if ($pkg.PSObject.Properties.Match('versions').Count -gt 0 -and @($pkg.versions).Count -gt 0) {
                        $versions = @($pkg.versions[0])
                    }
                } else {
                    $vUrl = "$SourceBaseUrl/_apis/packaging/feeds/$feedId/packages/$($pkg.id)/versions?api-version=$SourceApiVersion"
                    $vResp = Invoke-Ado -Url $vUrl
                    if (-not (Test-IsErr $vResp) -and $vResp.PSObject.Properties.Match('value').Count -gt 0) {
                        $versions = @($vResp.value)
                    } elseif ($pkg.PSObject.Properties.Match('versions').Count -gt 0) {
                        $versions = @($pkg.versions)
                    }
                }

                foreach ($ver in $versions) {
                    $verStr = $ver.version
                    $mapKey = "npm:$pkgName@$verStr"

                    if ($script:PackageMap.ContainsKey($mapKey)) {
                        $totalSkip++
                        continue
                    }

                    Pretty-Action "npm" "'$pkgName' v$verStr → feed '$feedName'"
                    if ($Execute) {
                        $file = Download-SourcePackage -FeedId $feedId -Protocol "Npm" -PackageName $pkgName -Version $verStr
                        if ($file) {
                            $totalDown++
                            $ok = Push-NpmPackage -FilePath $file -FeedName $feedName
                            if ($ok) {
                                $script:PackageMap[$mapKey] = "OK"
                                Save-Map $script:PackageMap $mapPaths.Package
                                $totalPush++
                            } else { $totalErr++ }
                        } else { $totalErr++ }
                    }
                }
            }
        }
    }

    Write-Status "Paquetes: $totalDown descargados, $totalPush publicados, $totalSkip omitidos, $totalErr errores" -Level OK
}

# ================================================================
# MAIN
# ================================================================
$_toolName    = "Migrate-ArtifactFeeds"
$_toolVersion = "1.0.0"
$_toolUpdate  = "2025-05-08"

Write-Host ""
Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Magenta
Write-Host "  │                                                          │" -ForegroundColor Magenta
Write-Host "  │   ■ ■  $_toolName  v$_toolVersion                  │" -ForegroundColor Magenta
Write-Host "  │        Last update: $_toolUpdate                        │" -ForegroundColor Magenta
Write-Host "  │        Azure Artifacts Migration                        │" -ForegroundColor Magenta
Write-Host "  │                                                          │" -ForegroundColor Magenta
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Source    : $SourceBaseUrl" -ForegroundColor Cyan
Write-Host "  Target    : $TargetOrgUrl / $TargetProject" -ForegroundColor Cyan
Write-Host "  Principal : $PrincipalFeed (hub)" -ForegroundColor Cyan
Write-Host "  Filtro    : $FeedFilter" -ForegroundColor Cyan
Write-Host "  Tipos     : $PackageTypes" -ForegroundColor Cyan
Write-Host "  Modo      : $(if ($Execute) { 'EXECUTE (real)' } else { 'DRY-RUN' })" -ForegroundColor Cyan
Write-Host ""

if (-not $Execute) {
    Write-Status "Modo DRY-RUN: no se realizaran cambios. Use -Execute para aplicar." -Level WARN
}

# Fase 1
$sourceFeeds = Get-SourceFeeds
if ($sourceFeeds.Count -eq 0) {
    Write-Status "No se encontraron feeds. Abortando." -Level ERROR
    exit 1
}

# Guardar inventario
$invPath = Join-Path $OutputDir "source-feeds-inventory.json"
$feedSummary = $sourceFeeds | ForEach-Object {
    @{
        name = $_.name
        scope = $_._scope
        project = $_._project
        isPrincipal = $_._isPrincipal
        nugetCount = @($_._nugetPackages).Count
        npmCount = @($_._npmPackages).Count
        upstreams = if ($_.PSObject.Properties.Match('upstreamSources').Count -gt 0) {
            @($_.upstreamSources | ForEach-Object { $_.name })
        } else { @() }
    }
}
$feedSummary | ConvertTo-Json -Depth 5 | Out-File -FilePath $invPath -Encoding UTF8
Write-Status "Inventario: $invPath" -Level OK

# Verificar que el principal existe en el inventario
$principalExists = $sourceFeeds | Where-Object { $_.name -eq $PrincipalFeed }
if (-not $principalExists) {
    Write-Status "WARN: Feed principal '$PrincipalFeed' no encontrado en origen. Todos los feeds se crearan como independientes." -Level WARN
}

# Fase 2
Create-TargetFeeds -SourceFeeds $sourceFeeds

# Fase 3
Configure-Upstreams -SourceFeeds $sourceFeeds

# Fase 4/5
Migrate-Packages -SourceFeeds $sourceFeeds

# ================================================================
# RESUMEN
# ================================================================
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  MIGRACION DE ARTIFACTS COMPLETADA                     ║" -ForegroundColor Green
Write-Host "  ║                                                         ║" -ForegroundColor Green
Write-Host "  ║  Archivos de salida:                                    ║" -ForegroundColor Green
Write-Host "  ║    - source-feeds-inventory.json  (inventario)          ║" -ForegroundColor Green
Write-Host "  ║    - mapping-feeds.json           (feedName -> id)      ║" -ForegroundColor Green
Write-Host "  ║    - mapping-packages.json        (pkg@ver -> status)   ║" -ForegroundColor Green
Write-Host "  ║    - migrate_artifacts_*.log       (log detallado)      ║" -ForegroundColor Green
Write-Host "  ║                                                         ║" -ForegroundColor Green
Write-Host "  ║  Topologia configurada:                                 ║" -ForegroundColor Green
Write-Host "  ║    $($PrincipalFeed) → Internet (npmjs, NuGet, Maven)" -ForegroundColor Green
$satellites = @($sourceFeeds | Where-Object { -not $_._isPrincipal })
foreach ($sat in $satellites) {
    Write-Host "  ║    $($sat.name) → $PrincipalFeed" -ForegroundColor Green
}
Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
