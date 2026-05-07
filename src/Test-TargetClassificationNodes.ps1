<#
.SYNOPSIS
    Test-TargetClassificationNodes.ps1
    Pre-valida que las Areas e Iteraciones referenciadas por los Test Plans
    y Test Cases del proyecto ORIGEN existan en el proyecto DESTINO.

.DESCRIPTION
    Antes de ejecutar Migrate-TestPlans.ps1 (con -Execute) conviene verificar
    que toda la jerarquia de Areas/Iteraciones que referencian los Test Plans
    y Test Cases ya existe en el destino. Si falta alguna, se puede:
      - Crearla manualmente en ADO Services
      - Crearla automaticamente con -CreateMissing

    Genera un reporte CSV/JSON con el estado de cada nodo y, opcionalmente,
    crea los nodos faltantes via REST API.

    Replace-rule: el primer segmento del path (que es el nombre del proyecto)
    se reemplaza de SourceProject por TargetProject antes de validar.

.PARAMETER SourceBaseUrl, SourcePat, SourceProject
    Igual que Migrate-TestPlans.ps1 (lee .env: ADO_SOURCE_BASE / ADO_SOURCE_PAT).

.PARAMETER TargetOrgUrl, TargetPat, TargetProject
    Igual que Migrate-TestPlans.ps1 (lee .env: ADO_TARGET_ORG_URL / ADO_TARGET_PAT / ADO_TARGET_PROJECT).

.PARAMETER OutputDir
    Default: .\testplans-migration

.PARAMETER ApiVersion / SourceApiVersion
    Versiones de API. Defaults: 7.1 / 5.0.

.PARAMETER CreateMissing
    Switch. Si esta presente, crea las areas/iteraciones faltantes en destino
    respetando la jerarquia (de raiz hacia hojas).

.PARAMETER EnvFile
    Ruta al .env. Default: junto al script.

.EXAMPLE
    # Solo reportar
    .\Test-TargetClassificationNodes.ps1 -SourceProject A -TargetProject A

.EXAMPLE
    # Crear lo que falte
    .\Test-TargetClassificationNodes.ps1 -SourceProject A -TargetProject A -CreateMissing

.NOTES
    Solo lectura en origen. En destino: lectura + (opcional) creacion de nodos.
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
    [string]$ApiVersion = "7.1",
    [string]$SourceApiVersion = "5.0",

    [switch]$CreateMissing,

    [string]$EnvFile = (Join-Path $PSScriptRoot ".env")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ----------------------------------------------------------------
# .env
# ----------------------------------------------------------------
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

if (-not $SourceBaseUrl) { Write-Host "ERROR: Falta SourceBaseUrl" -ForegroundColor Red; exit 1 }
if (-not $TargetOrgUrl)  { Write-Host "ERROR: Falta TargetOrgUrl" -ForegroundColor Red; exit 1 }
if (-not $TargetProject) { Write-Host "ERROR: Falta TargetProject" -ForegroundColor Red; exit 1 }
if (-not $TargetPat)     { Write-Host "ERROR: Falta TargetPat" -ForegroundColor Red; exit 1 }

# Normalizar URLs (sin barra final)
$SourceBaseUrl = $SourceBaseUrl.TrimEnd('/')
$TargetOrgUrl  = $TargetOrgUrl.TrimEnd('/')

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFilePath = Join-Path $OutputDir "validate_classification_$ts.log"

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
        $params["Body"] = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 20 -Compress) }
    }
    try { return Invoke-RestMethod @params }
    catch {
        $code = "Unknown"; $msg = $_.Exception.Message
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch {}
        return [PSCustomObject]@{ _error=$true; _statusCode=$code; _message=$msg; _url=$Url }
    }
}
function IsErr { param($r) if ($null -eq $r) { return $true }; if ($r.PSObject.Properties.Match('_error').Count -gt 0) { return [bool]$r._error }; return $false }
function ErrMsg { param($r) if ($null -eq $r) { return "null" }; if ($r.PSObject.Properties.Match('_message').Count -gt 0) { return $r._message }; return "unknown" }
function ErrCode { param($r) if ($null -ne $r -and $r.PSObject.Properties.Match('_statusCode').Count -gt 0) { return $r._statusCode }; return "?" }
function ErrUrl  { param($r) if ($null -ne $r -and $r.PSObject.Properties.Match('_url').Count -gt 0) { return $r._url }; return "" }

# Verificar que el proyecto destino existe y el PAT funciona
function Test-TargetProjectAccess {
    $url = "$TargetOrgUrl/_apis/projects/$([uri]::EscapeDataString($TargetProject))?api-version=$ApiVersion"
    $r = Invoke-Ado -Url $url -Pat $TargetPat
    if (IsErr $r) {
        Log "No se puede acceder al proyecto destino '$TargetProject' en $TargetOrgUrl" "ERROR"
        Log "  HTTP $(ErrCode $r): $(ErrMsg $r)" "ERROR"
        Log "  URL: $url" "ERROR"
        Log "Verifica: 1) TargetOrgUrl correcta (https://dev.azure.com/{org}), 2) nombre exacto del proyecto, 3) PAT con scope 'Project and Team (Read)' + 'Work Items (Read & Write)'" "WARN"
        return $false
    }
    Log "Proyecto destino verificado: '$($r.name)' (id=$($r.id))" "OK"
    return $true
}

# ----------------------------------------------------------------
# Coleccion de paths referenciados en ORIGEN
# ----------------------------------------------------------------
function Collect-SourcePaths {
    $areas = New-Object System.Collections.Generic.HashSet[string]
    $iters = New-Object System.Collections.Generic.HashSet[string]

    Log "Recolectando paths de Test Plans en origen..."
    $url = "$SourceBaseUrl/$SourceProject/_apis/test/plans?api-version=$SourceApiVersion"
    $r = Invoke-Ado -Url $url -Pat $SourcePat
    if (-not (IsErr $r)) {
        foreach ($p in @($r.value)) {
            if ($p.PSObject.Properties.Match('area').Count -gt 0 -and $p.area -and $p.area.PSObject.Properties.Match('name').Count -gt 0 -and $p.area.name) {
                [void]$areas.Add($p.area.name)
            }
            if ($p.PSObject.Properties.Match('iteration').Count -gt 0 -and $p.iteration) {
                [void]$iters.Add([string]$p.iteration)
            }
        }
    } else {
        Log "Error obteniendo plans: $(ErrMsg $r)" "ERROR"
    }

    Log "Recolectando paths de Test Cases en origen (WIQL)..."
    $wiql = @{
        query = "SELECT [System.Id],[System.AreaPath],[System.IterationPath] FROM WorkItems WHERE [System.TeamProject] = '$SourceProject' AND [System.WorkItemType] = 'Test Case'"
    }
    $wUrl = "$SourceBaseUrl/$SourceProject/_apis/wit/wiql?api-version=$SourceApiVersion"
    $wr = Invoke-Ado -Url $wUrl -Method Post -Pat $SourcePat -Body $wiql
    if (-not (IsErr $wr) -and $wr.workItems.Count -gt 0) {
        $ids = @($wr.workItems | ForEach-Object { $_.id })
        $batchSize = 200
        for ($i = 0; $i -lt $ids.Count; $i += $batchSize) {
            $chunk = $ids[$i..([Math]::Min($i + $batchSize - 1, $ids.Count - 1))]
            $idList = $chunk -join ","
            $bUrl = "$SourceBaseUrl/$SourceProject/_apis/wit/workitems?ids=$idList&fields=System.AreaPath,System.IterationPath&api-version=$SourceApiVersion"
            $br = Invoke-Ado -Url $bUrl -Pat $SourcePat
            if (-not (IsErr $br)) {
                foreach ($wi in @($br.value)) {
                    if ($wi.fields.PSObject.Properties.Match('System.AreaPath').Count -gt 0 -and $wi.fields."System.AreaPath") { [void]$areas.Add($wi.fields."System.AreaPath") }
                    if ($wi.fields.PSObject.Properties.Match('System.IterationPath').Count -gt 0 -and $wi.fields."System.IterationPath") { [void]$iters.Add($wi.fields."System.IterationPath") }
                }
            }
        }
    }

    return @{ Areas = $areas; Iterations = $iters }
}

# ----------------------------------------------------------------
# Verificacion de existencia en DESTINO via classificationnodes
# ----------------------------------------------------------------
function Test-NodeExists {
    param([string]$StructureGroup, [string]$RelativePath)  # 'areas' | 'iterations', path SIN el proyecto
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $true }
    $encoded = ($RelativePath.Split('\') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $url = "$TargetOrgUrl/$TargetProject/_apis/wit/classificationnodes/$StructureGroup/$encoded`?api-version=$ApiVersion"
    $r = Invoke-Ado -Url $url -Pat $TargetPat
    return -not (IsErr $r)
}

function New-Node {
    param([string]$StructureGroup, [string]$ParentRelative, [string]$Name)
    $body = @{ name = $Name }
    $url = if ([string]::IsNullOrWhiteSpace($ParentRelative)) {
        "$TargetOrgUrl/$TargetProject/_apis/wit/classificationnodes/$StructureGroup`?api-version=$ApiVersion"
    } else {
        $encoded = ($ParentRelative.Split('\') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        "$TargetOrgUrl/$TargetProject/_apis/wit/classificationnodes/$StructureGroup/$encoded`?api-version=$ApiVersion"
    }
    return Invoke-Ado -Url $url -Method Post -Pat $TargetPat -Body $body
}

function Convert-ToTargetPath {
    param([string]$Path)
    # Reemplaza el primer segmento (proyecto) por TargetProject
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $parts = $Path.Split('\')
    $parts[0] = $TargetProject
    return ($parts -join '\')
}

function Get-RelativePath {
    param([string]$FullPath)
    # Quita el primer segmento (TargetProject)
    $parts = $FullPath.Split('\')
    if ($parts.Count -le 1) { return "" }
    return ($parts[1..($parts.Count - 1)] -join '\')
}

# ----------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Validate Classification Nodes (Areas + Iterations)" -ForegroundColor Cyan
Write-Host "  Source : $SourceBaseUrl / $SourceProject" -ForegroundColor Cyan
Write-Host "  Target : $TargetOrgUrl / $TargetProject" -ForegroundColor Cyan
Write-Host "  Mode   : $(if ($CreateMissing) { 'CREATE MISSING' } else { 'REPORT ONLY' })" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-TargetProjectAccess)) { exit 1 }

$collected = Collect-SourcePaths
$areaPaths = @($collected.Areas) | Sort-Object
$iterPaths = @($collected.Iterations) | Sort-Object
Log "Areas referenciadas: $($areaPaths.Count) | Iteraciones referenciadas: $($iterPaths.Count)" "OK"

$report = New-Object System.Collections.Generic.List[object]

function Process-Set {
    param([string[]]$Paths, [string]$StructureGroup)  # 'areas' | 'iterations'
    foreach ($p in $Paths) {
        $tgt = Convert-ToTargetPath -Path $p
        $rel = Get-RelativePath -FullPath $tgt
        $exists = Test-NodeExists -StructureGroup $StructureGroup -RelativePath $rel
        $status = if ($exists) { "OK" } else { "MISSING" }
        if ($exists) { Log "  [OK] $StructureGroup : $tgt" "OK" }
        else         { Log "  [MISS] $StructureGroup : $tgt" "MISS" }

        $created = $false
        if (-not $exists -and $CreateMissing) {
            # Crear desde la raiz hacia la hoja (idempotente)
            $segments = $rel.Split('\')
            $accumulated = ""
            for ($i = 0; $i -lt $segments.Count; $i++) {
                $name = $segments[$i]
                $parent = $accumulated
                if (-not (Test-NodeExists -StructureGroup $StructureGroup -RelativePath ($(if ($parent) { "$parent\$name" } else { $name })))) {
                    Log "    Creando $StructureGroup '$name' bajo '$(if ($parent) { $parent } else { '<root>' })'" "INFO"
                    $r = New-Node -StructureGroup $StructureGroup -ParentRelative $parent -Name $name
                    if (IsErr $r) {
                        Log "      ERROR HTTP $(ErrCode $r): $(ErrMsg $r)" "ERROR"
                        Log "      URL: $(ErrUrl $r)" "ERROR"
                        if ("$(ErrCode $r)" -eq "404") {
                            Log "      404 al crear suele indicar PAT sin permiso de escritura sobre Project Settings o nombre de proyecto incorrecto." "WARN"
                        }
                        break
                    }
                }
                $accumulated = if ($parent) { "$parent\$name" } else { $name }
            }
            $created = (Test-NodeExists -StructureGroup $StructureGroup -RelativePath $rel)
            if ($created) { $status = "CREATED" }
        }

        $report.Add([PSCustomObject]@{
            Type        = $StructureGroup
            SourcePath  = $p
            TargetPath  = $tgt
            Status      = $status
            Created     = $created
        }) | Out-Null
    }
}

Process-Set -Paths $areaPaths -StructureGroup "areas"
Process-Set -Paths $iterPaths -StructureGroup "iterations"

# Reportes
$csv  = Join-Path $OutputDir "classification_validation_$ts.csv"
$json = Join-Path $OutputDir "classification_validation_$ts.json"
$report | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$report | ConvertTo-Json -Depth 5 | Out-File -FilePath $json -Encoding UTF8

$missing = @($report | Where-Object { $_.Status -eq "MISSING" })
$created = @($report | Where-Object { $_.Status -eq "CREATED" })

Write-Host ""
Log "=== RESUMEN ===" "OK"
Log "Total nodos analizados : $($report.Count)" "OK"
Log "Existentes en destino  : $((@($report | Where-Object { $_.Status -eq 'OK' })).Count)" "OK"
Log "Creados                : $($created.Count)" $(if ($created.Count -gt 0) { 'OK' } else { 'INFO' })
Log "Faltantes (no creados) : $($missing.Count)" $(if ($missing.Count -gt 0) { 'WARN' } else { 'OK' })
Log "CSV  : $csv" "OK"
Log "JSON : $json" "OK"

if ($missing.Count -gt 0 -and -not $CreateMissing) {
    Write-Host ""
    Log "Hay nodos faltantes. Vuelve a ejecutar con -CreateMissing para crearlos automaticamente." "WARN"
}
