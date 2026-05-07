<#
.SYNOPSIS
    Build-IdentityMap.ps1
    Genera un mapping de identidades (owners, asignados) ORIGEN -> DESTINO
    para usar en la migracion de Test Plans / Test Cases.

.DESCRIPTION
    Recolecta todas las identidades referenciadas en el proyecto ORIGEN
    (owners de Test Plans, owners de suites, asignados de Test Cases) y para
    cada una intenta resolver una identidad equivalente en el DESTINO usando
    el endpoint de Identities (busqueda por mail/displayName).

    Produce un JSON con la forma:
      {
        "by_email":       { "user@org.com": { "displayName":"...", "uniqueName":"..." } },
        "by_displayName": { "Nombre Apellido": { ... } },
        "unresolved":     [ "user@org.com", ... ]
      }

    Este JSON puede pasarse a Migrate-TestPlans.ps1 (parametro -IdentityMapFile)
    para reasignar owners/asignados al crear plans y test cases en destino.

.PARAMETER OutputFile
    Ruta de salida del JSON. Default: <OutputDir>/identity-map.json

.PARAMETER Interactive
    Si esta presente, para cada identidad no resuelta automaticamente solicita
    al usuario el uniqueName/email del destino (o ENTER para dejar como unresolved).

.EXAMPLE
    .\Build-IdentityMap.ps1 -SourceProject A -TargetProject A

.EXAMPLE
    .\Build-IdentityMap.ps1 -SourceProject A -TargetProject A -Interactive
#>

[CmdletBinding()]
param(
    [string]$SourceBaseUrl,
    [string]$SourcePat,
    [Parameter(Mandatory = $true)][string]$SourceProject,

    [string]$TargetOrgUrl,
    [string]$TargetPat,
    [string]$TargetProject,

    [string]$OutputDir = ".\testplans-migration",
    [string]$OutputFile,
    [string]$ApiVersion = "7.1",
    [string]$SourceApiVersion = "5.0",

    [switch]$Interactive,

    [string]$EnvFile = (Join-Path $PSScriptRoot ".env")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

if (-not $SourceBaseUrl -or -not $TargetOrgUrl -or -not $TargetProject -or -not $TargetPat) {
    Write-Host "ERROR: Faltan variables de origen/destino." -ForegroundColor Red; exit 1
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
if (-not $OutputFile) { $OutputFile = Join-Path $OutputDir "identity-map.json" }
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFilePath = Join-Path $OutputDir "identity_map_$ts.log"

function Log {
    param([string]$Msg, [string]$Level = "INFO")
    $color = @{ INFO="Cyan"; WARN="Yellow"; ERROR="Red"; OK="Green"; MISS="Magenta" }[$Level]
    if (-not $color) { $color = "White" }
    $line = "[$(Get-Date -Format HH:mm:ss)][$Level] $Msg"
    Write-Host $line -ForegroundColor $color
    $line | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
}

function Invoke-Ado {
    param([string]$Url, [string]$Method="Get", [string]$Pat, $Body=$null, [string]$ContentType="application/json")
    $headers = @{}
    if ($Pat) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        $headers["Authorization"] = "Basic $b64"
    }
    $params = @{ Uri=$Url; Method=$Method; Headers=$headers; ContentType=$ContentType }
    if (-not $Pat) { $params["UseDefaultCredentials"] = $true }
    if ($null -ne $Body) {
        $params["Body"] = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 10 -Compress) }
    }
    try { return Invoke-RestMethod @params }
    catch {
        $code = "Unknown"; $msg = $_.Exception.Message
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch {}
        return [PSCustomObject]@{ _error=$true; _statusCode=$code; _message=$msg }
    }
}
function IsErr { param($r) if ($null -eq $r) { return $true }; if ($r.PSObject.Properties.Match('_error').Count -gt 0) { return [bool]$r._error }; return $false }

# ----------------------------------------------------------------
# Recolectar identidades de origen
# ----------------------------------------------------------------
function Add-Identity {
    param([hashtable]$Bag, $IdentityRef)
    if ($null -eq $IdentityRef) { return }
    $email = ""
    $name  = ""
    if ($IdentityRef.PSObject.Properties.Match('uniqueName').Count -gt 0) { $email = $IdentityRef.uniqueName }
    if (-not $email -and $IdentityRef.PSObject.Properties.Match('mailAddress').Count -gt 0) { $email = $IdentityRef.mailAddress }
    if ($IdentityRef.PSObject.Properties.Match('displayName').Count -gt 0) { $name = $IdentityRef.displayName }
    if (-not $email -and -not $name) { return }
    $key = if ($email) { $email.ToLower() } else { "name::$name" }
    if (-not $Bag.ContainsKey($key)) {
        $Bag[$key] = [PSCustomObject]@{ email = $email; displayName = $name }
    }
}

function Collect-SourceIdentities {
    $bag = @{}

    Log "Plans (owners)..."
    $r = Invoke-Ado -Url "$SourceBaseUrl/$SourceProject/_apis/test/plans?api-version=$SourceApiVersion" -Pat $SourcePat
    if (-not (IsErr $r)) {
        foreach ($p in @($r.value)) {
            if ($p.PSObject.Properties.Match('owner').Count -gt 0) { Add-Identity $bag $p.owner }
        }
    }

    Log "Test Cases (System.AssignedTo, System.CreatedBy)..."
    $wiql = @{
        query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$SourceProject' AND [System.WorkItemType] = 'Test Case'"
    }
    $wr = Invoke-Ado -Url "$SourceBaseUrl/$SourceProject/_apis/wit/wiql?api-version=$SourceApiVersion" -Method Post -Pat $SourcePat -Body $wiql
    if (-not (IsErr $wr) -and $wr.workItems.Count -gt 0) {
        $ids = @($wr.workItems | ForEach-Object { $_.id })
        $batchSize = 200
        for ($i = 0; $i -lt $ids.Count; $i += $batchSize) {
            $chunk = $ids[$i..([Math]::Min($i + $batchSize - 1, $ids.Count - 1))]
            $idList = $chunk -join ","
            $bUrl = "$SourceBaseUrl/$SourceProject/_apis/wit/workitems?ids=$idList&fields=System.AssignedTo,System.CreatedBy&api-version=$SourceApiVersion"
            $br = Invoke-Ado -Url $bUrl -Pat $SourcePat
            if (-not (IsErr $br)) {
                foreach ($wi in @($br.value)) {
                    if ($wi.fields.PSObject.Properties.Match('System.AssignedTo').Count -gt 0) { Add-Identity $bag $wi.fields."System.AssignedTo" }
                    if ($wi.fields.PSObject.Properties.Match('System.CreatedBy').Count -gt 0)  { Add-Identity $bag $wi.fields."System.CreatedBy"  }
                }
            }
        }
    }

    return $bag
}

# ----------------------------------------------------------------
# Resolucion en destino via /_apis/identities
# ----------------------------------------------------------------
function Find-TargetIdentity {
    param([string]$Search)  # email o displayName
    if ([string]::IsNullOrWhiteSpace($Search)) { return $null }
    # Endpoint: vssps.dev.azure.com (org-level); aceptamos que TargetOrgUrl es https://dev.azure.com/{org}
    $org = $TargetOrgUrl -replace 'https?://dev\.azure\.com/', '' -replace '/$', ''
    $url = "https://vssps.dev.azure.com/$org/_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($Search))&api-version=$ApiVersion"
    $r = Invoke-Ado -Url $url -Pat $TargetPat
    if (IsErr $r) { return $null }
    if ($r.count -eq 0 -or -not $r.value) { return $null }
    # Preferir match exacto por mail o uniqueName
    $exact = $r.value | Where-Object {
        ($_.PSObject.Properties.Match('properties').Count -gt 0 -and $_.properties.PSObject.Properties.Match('Mail').Count -gt 0 -and $_.properties.Mail.'$value' -eq $Search) -or
        ($_.PSObject.Properties.Match('descriptor').Count -gt 0 -and $_.providerDisplayName -eq $Search)
    } | Select-Object -First 1
    if ($exact) { return $exact }
    return $r.value[0]
}

function Get-IdentityFields {
    param($Id)
    $email = ""
    if ($Id.PSObject.Properties.Match('properties').Count -gt 0 -and $Id.properties -and $Id.properties.PSObject.Properties.Match('Mail').Count -gt 0) {
        try { $email = $Id.properties.Mail.'$value' } catch {}
    }
    if (-not $email -and $Id.PSObject.Properties.Match('properties').Count -gt 0 -and $Id.properties.PSObject.Properties.Match('Account').Count -gt 0) {
        try { $email = $Id.properties.Account.'$value' } catch {}
    }
    $name = if ($Id.PSObject.Properties.Match('providerDisplayName').Count -gt 0) { $Id.providerDisplayName } else { "" }
    return @{ uniqueName = $email; displayName = $name }
}

# ----------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Build Identity Map (Source -> Target)" -ForegroundColor Cyan
Write-Host "  Source : $SourceBaseUrl / $SourceProject" -ForegroundColor Cyan
Write-Host "  Target : $TargetOrgUrl / $TargetProject" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$bag = Collect-SourceIdentities
Log "Identidades unicas en origen: $($bag.Count)" "OK"

$byEmail = @{}
$byName  = @{}
$unresolved = New-Object System.Collections.Generic.List[string]

foreach ($k in $bag.Keys) {
    $src = $bag[$k]
    $search = if ($src.email) { $src.email } else { $src.displayName }
    $found = Find-TargetIdentity -Search $search
    if (-not $found -and $src.displayName -and $src.email) {
        $found = Find-TargetIdentity -Search $src.displayName
    }
    if ($found) {
        $f = Get-IdentityFields -Id $found
        Log "  [OK] '$search' -> '$($f.uniqueName)' / '$($f.displayName)'" "OK"
        if ($src.email) { $byEmail[$src.email.ToLower()] = $f }
        if ($src.displayName) { $byName[$src.displayName] = $f }
    }
    elseif ($Interactive) {
        Write-Host ""
        Write-Host "No se resolvio: '$search' (display='$($src.displayName)')" -ForegroundColor Yellow
        $manual = Read-Host "  Ingresa uniqueName/email destino (ENTER para omitir)"
        if ($manual) {
            $f2 = Find-TargetIdentity -Search $manual
            if ($f2) {
                $fields = Get-IdentityFields -Id $f2
                if ($src.email) { $byEmail[$src.email.ToLower()] = $fields }
                if ($src.displayName) { $byName[$src.displayName] = $fields }
                Log "  [MANUAL] '$search' -> '$($fields.uniqueName)'" "OK"
                continue
            }
        }
        Log "  [MISS] '$search'" "MISS"
        $unresolved.Add($search) | Out-Null
    }
    else {
        Log "  [MISS] '$search'" "MISS"
        $unresolved.Add($search) | Out-Null
    }
}

$out = [PSCustomObject]@{
    generatedAt    = (Get-Date -Format "o")
    sourceProject  = $SourceProject
    targetProject  = $TargetProject
    by_email       = $byEmail
    by_displayName = $byName
    unresolved     = $unresolved
}
$out | ConvertTo-Json -Depth 8 | Out-File -FilePath $OutputFile -Encoding UTF8

Write-Host ""
Log "=== RESUMEN ===" "OK"
Log "Resueltas (email)   : $($byEmail.Count)" "OK"
Log "Resueltas (nombre)  : $($byName.Count)" "OK"
Log "No resueltas        : $($unresolved.Count)" $(if ($unresolved.Count -gt 0) { 'WARN' } else { 'OK' })
Log "Mapping JSON        : $OutputFile" "OK"
Log "Para usar en migracion: .\Migrate-TestPlans.ps1 ... -IdentityMapFile $OutputFile" "INFO"
