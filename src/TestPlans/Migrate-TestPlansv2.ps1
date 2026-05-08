<#
.SYNOPSIS
    Migrate-TestPlans.ps1
    Migra Test Plans, Suites, Test Cases, Configuraciones y exporta Test Runs
    desde Azure DevOps Server OnPrem hacia Azure DevOps Services (Cloud).

.DESCRIPTION
    Pipeline de migracion en fases con dry-run por defecto y mappings persistentes
    en JSON para idempotencia y reanudacion.

    Fases:
      1) Inventario de origen (plans, suites, test cases, configs)
      2) Migrar Test Configurations      (POST /test/configurations)
      3) Migrar Test Cases (work items)   (POST /wit/workitems/$Test Case)
    3.5) Migrar Requirement Work Items    (POST /wit/workitems/$<Type>)
      4) Migrar Test Plans                (POST /test/plans)
      5) Migrar Test Suites jerarquicas   (POST /test/Plans/{planId}/suites)
      6) Asociar Test Cases a Suites      (POST .../suites/{id}/testcases)
      7) Exportar Test Runs / Results historicos a JSON (archivo, NO se recrean)

    REQUISITOS PREVIOS EN DESTINO:
    - El Team Project destino debe existir.
    - Las Areas / Iteraciones referenciadas deben existir (DMT o creacion previa).
    - Si los test cases ya fueron migrados por DMT, usar -SkipTestCases y
      proveer -TestCaseMappingFile con el mapping sourceId -> targetId.

    LIMITACIONES:
    - No se reinyectan ejecuciones historicas (Runs/Results). Se exportan a JSON.
    - Los owners se mapean por displayName/email; si no existen en destino se
      deja el owner del PAT.
    - Suites query-based: la WIQL se copia tal cual; si referencia areas que no
      existen en destino, fallara (revisar mapping de areas).

    CAMBIOS v1.1.0:
    - FASE 3.5: Migracion de Requirement Work Items referenciados por
      RequirementTestSuites. Sin esto, las suites tipo RequirementTestSuite
      fallan al crearse porque el requirementId no existe en el destino.
    - Fallback: si un requirementId no puede resolverse, la suite se convierte
      a StaticTestSuite para preservar la jerarquia.
    - BFS resiliente: un fallo en una suite no bloquea las hermanas.
    - Nuevos parametros: -SkipRequirements, -RequirementMappingFile.

.PARAMETER SourceBaseUrl
    URL base de la collection origen (ADO Server). Lee $env:ADO_SOURCE_BASE.

.PARAMETER SourcePat
    PAT del ADO Server origen. Lee $env:ADO_SOURCE_PAT.

.PARAMETER SourceProject
    Nombre del Team Project origen.

.PARAMETER TargetOrgUrl
    URL de la organizacion destino (ej: https://dev.azure.com/miorg).
    Lee $env:ADO_TARGET_ORG_URL.

.PARAMETER TargetPat
    PAT del ADO Services destino. Lee $env:ADO_TARGET_PAT.

.PARAMETER TargetProject
    Nombre del Team Project destino. Lee $env:ADO_TARGET_PROJECT.

.PARAMETER OutputDir
    Directorio de salida (mappings, logs, export de runs). Default: .\testplans-migration

.PARAMETER ApiVersion
    Version de API. Default: 7.1

.PARAMETER SourceApiVersion
    Version de API para origen (ADO Server suele requerir 5.0 o 6.0). Default: 5.0

.PARAMETER Execute
    Switch. Sin este flag el script corre en dry-run (no escribe en destino).

.PARAMETER SkipTestCases
    No crea test cases en destino. Requiere -TestCaseMappingFile.

.PARAMETER SkipRequirements
    No migra Requirement Work Items. Requiere -RequirementMappingFile si hay
    RequirementTestSuites en el origen.

.PARAMETER SkipConfigurations
    No migra Test Configurations.

.PARAMETER SkipRunsExport
    No exporta Test Runs / Results historicos.

.PARAMETER TestCaseMappingFile
    Ruta a JSON con mapping previo { "sourceId": targetId, ... }.
    Si existe se carga al inicio para idempotencia.

.PARAMETER RequirementMappingFile
    Ruta a JSON con mapping de requisitos { "sourceReqId": targetReqId, ... }.
    Util cuando los requisitos ya fueron migrados por DMT.

.PARAMETER WorkItemTypeMap
    Hashtable para mapear tipos de work item entre process templates distintos.
    Ej: @{ "Product Backlog Item" = "User Story" } para Scrum -> Agile.
    Si no se proporciona, el script auto-detecta los tipos del destino
    y construye el mapeo automaticamente.

.PARAMETER PlanFilter
    Filtro wildcard por nombre de Test Plan. Default: * (todos).

.PARAMETER EnvFile
    Ruta al .env. Default: junto al script.

.EXAMPLE
    # Dry-run completo
    .\Migrate-TestPlans.ps1 -SourceProject "MiProyecto" -TargetProject "MiProyectoCloud"

.EXAMPLE
    # Ejecutar migracion real
    .\Migrate-TestPlans.ps1 -SourceProject "MiProyecto" -TargetProject "MiProyectoCloud" -Execute

.EXAMPLE
    # Test cases ya migrados por DMT, solo migrar plans/suites
    .\Migrate-TestPlans.ps1 -SourceProject "P" -TargetProject "P" -SkipTestCases `
        -TestCaseMappingFile .\dmt-testcase-mapping.json -Execute

.EXAMPLE
    # Requisitos ya migrados por DMT
    .\Migrate-TestPlans.ps1 -SourceProject "P" -TargetProject "P" -SkipRequirements `
        -RequirementMappingFile .\dmt-requirement-mapping.json -Execute

.NOTES
    Operacion: Solo lectura en origen, escritura en destino (con -Execute).
#>
[CmdletBinding()]
param(
    [string]$SourceBaseUrl,
    [string]$SourcePat,
    [Parameter(Mandatory = $true)][string]$SourceProject,
    [string]$TargetOrgUrl,
    [string]$TargetPat,
    [string]$TargetProject,
    [string]$OutputDir       = ".\testplans-migration",
    [string]$ApiVersion      = "7.1",
    [string]$SourceApiVersion = "5.0",
    [switch]$Execute,
    [switch]$SkipTestCases,
    [switch]$SkipRequirements,
    [switch]$SkipConfigurations,
    [switch]$SkipRunsExport,
    [string]$TestCaseMappingFile,
    [string]$RequirementMappingFile,
    [string]$IdentityMapFile,
    [hashtable]$WorkItemTypeMap = @{},
    [string]$PlanFilter      = "*",
    [string]$EnvFile         = (Join-Path (Split-Path $PSScriptRoot -Parent) ".env")
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
if (-not $SourcePat)     { $SourcePat     = $env:ADO_SOURCE_PAT }
if (-not $TargetOrgUrl)  { $TargetOrgUrl  = $env:ADO_TARGET_ORG_URL }
if (-not $TargetPat)     { $TargetPat     = $env:ADO_TARGET_PAT }
if (-not $TargetProject) { $TargetProject = $env:ADO_TARGET_PROJECT }

# Fallback compatibilidad con ADO_BASE / ADO_PAT del script de inventario
if (-not $SourceBaseUrl) { $SourceBaseUrl = $env:ADO_BASE }
if (-not $SourcePat)     { $SourcePat     = $env:ADO_PAT }

if (-not $SourceBaseUrl) { Write-Host "ERROR: Falta SourceBaseUrl (ADO_SOURCE_BASE)." -ForegroundColor Red; exit 1 }
if (-not $TargetOrgUrl)  { Write-Host "ERROR: Falta TargetOrgUrl (ADO_TARGET_ORG_URL)." -ForegroundColor Red; exit 1 }
if (-not $TargetProject) { Write-Host "ERROR: Falta TargetProject (ADO_TARGET_PROJECT)." -ForegroundColor Red; exit 1 }
if (-not $TargetPat)     { Write-Host "ERROR: Falta TargetPat (ADO_TARGET_PAT)." -ForegroundColor Red; exit 1 }
if (-not $SourcePat)     { Write-Host "WARN: ADO_SOURCE_PAT vacio, usando credenciales Windows." -ForegroundColor Yellow }

# ----------------------------------------------------------------
# Logging
# ----------------------------------------------------------------
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFilePath = Join-Path $OutputDir "migrate_testplans_$logTimestamp.log"

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO"  { "Cyan" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "OK"    { "Green" }
        "DRY"   { "Magenta" }
        default { "White" }
    }
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $color
    if ($script:LogFilePath) { $line | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8 }
}

# ----------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------
function Invoke-Ado {
    param(
        [string]$Url,
        [string]$Method = "Get",
        [string]$Pat,
        $Body = $null,
        [string]$ContentType = "application/json"
    )
    $headers = @{}
    if ($Pat) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        $headers["Authorization"] = "Basic $b64"
    }
    $params = @{
        Uri         = $Url
        Method      = $Method
        Headers     = $headers
        ContentType = $ContentType
    }
    if (-not $Pat) { $params["UseDefaultCredentials"] = $true }
    if ($null -ne $Body) {
        if ($Body -is [string]) { $params["Body"] = $Body }
        else { $params["Body"] = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $code = "Unknown"; $msg = $_.Exception.Message
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        $detail = ""
        try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message } } catch { }
        if ($detail) { $msg = "$msg | Detail: $detail" }
        return [PSCustomObject]@{ _error = $true; _statusCode = $code; _message = $msg; _url = $Url }
    }
}

function Test-IsErr { param($r) if ($null -eq $r) { return $true }; if ($r.PSObject.Properties.Match('_error').Count -gt 0) { return [bool]$r._error }; return $false }
function Get-ErrMsg { param($r) if ($null -eq $r) { return "null" }; if ($r.PSObject.Properties.Match('_message').Count -gt 0) { return $r._message }; return "unknown" }

# ----------------------------------------------------------------
# Mapping files
# ----------------------------------------------------------------
$script:TestCaseMap    = @{}   # sourceId -> targetId
$script:RequirementMap = @{}   # sourceReqId -> targetReqId
$script:ConfigMap      = @{}   # sourceId -> targetId
$script:PlanMap        = @{}   # sourceId -> targetId
$script:SuiteMap       = @{}   # "$planId/$suiteId" -> targetSuiteId

$paths = @{
    TestCase    = Join-Path $OutputDir "mapping-testcases.json"
    Requirement = Join-Path $OutputDir "mapping-requirements.json"
    Config      = Join-Path $OutputDir "mapping-configurations.json"
    Plan        = Join-Path $OutputDir "mapping-plans.json"
    Suite       = Join-Path $OutputDir "mapping-suites.json"
}

function Load-Map {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            $obj = Get-Content -Raw -Path $Path | ConvertFrom-Json
            $h = @{}
            $obj.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
            return $h
        } catch { return @{} }
    }
    return @{}
}

function Save-Map { param([hashtable]$Map, [string]$Path) ($Map | ConvertTo-Json -Depth 5) | Out-File -FilePath $Path -Encoding UTF8 }

# Cargar mappings previos
if ($TestCaseMappingFile -and (Test-Path $TestCaseMappingFile)) {
    $script:TestCaseMap = Load-Map -Path $TestCaseMappingFile
    Write-Status "Mapping de test cases cargado desde $TestCaseMappingFile ($($script:TestCaseMap.Count) entradas)" -Level OK
} elseif (Test-Path $paths.TestCase) {
    $script:TestCaseMap = Load-Map -Path $paths.TestCase
}

if ($RequirementMappingFile -and (Test-Path $RequirementMappingFile)) {
    $script:RequirementMap = Load-Map -Path $RequirementMappingFile
    Write-Status "Mapping de requisitos cargado desde $RequirementMappingFile ($($script:RequirementMap.Count) entradas)" -Level OK
} elseif (Test-Path $paths.Requirement) {
    $script:RequirementMap = Load-Map -Path $paths.Requirement
}

$script:ConfigMap = Load-Map -Path $paths.Config
$script:PlanMap   = Load-Map -Path $paths.Plan
$script:SuiteMap  = Load-Map -Path $paths.Suite

# Identity map (Source -> Target) generado por Build-IdentityMap.ps1
$script:IdentityByEmail = @{}
$script:IdentityByName  = @{}

if ($IdentityMapFile -and (Test-Path $IdentityMapFile)) {
    try {
        $idmap = Get-Content -Raw -Path $IdentityMapFile | ConvertFrom-Json
        if ($idmap.PSObject.Properties.Match('by_email').Count -gt 0 -and $idmap.by_email) {
            $idmap.by_email.PSObject.Properties | ForEach-Object { $script:IdentityByEmail[$_.Name.ToLower()] = $_.Value }
        }
        if ($idmap.PSObject.Properties.Match('by_displayName').Count -gt 0 -and $idmap.by_displayName) {
            $idmap.by_displayName.PSObject.Properties | ForEach-Object { $script:IdentityByName[$_.Name] = $_.Value }
        }
        Write-Status "Identity map cargado: $($script:IdentityByEmail.Count) por email, $($script:IdentityByName.Count) por nombre" -Level OK
    } catch {
        Write-Status "No se pudo cargar IdentityMapFile: $_" -Level WARN
    }
}

function Resolve-TargetIdentity {
    param($SourceIdentity)
    if ($null -eq $SourceIdentity) { return $null }
    $email = ""; $name = ""
    if ($SourceIdentity.PSObject.Properties.Match('uniqueName').Count -gt 0) { $email = $SourceIdentity.uniqueName }
    if (-not $email -and $SourceIdentity.PSObject.Properties.Match('mailAddress').Count -gt 0) { $email = $SourceIdentity.mailAddress }
    if ($SourceIdentity.PSObject.Properties.Match('displayName').Count -gt 0) { $name = $SourceIdentity.displayName }

    if ($email -and $script:IdentityByEmail.ContainsKey($email.ToLower())) { return $script:IdentityByEmail[$email.ToLower()] }
    if ($name -and $script:IdentityByName.ContainsKey($name)) { return $script:IdentityByName[$name] }
    return $null
}

function Resolve-TargetIdentityString {
    param([string]$RawValue)
    if ([string]::IsNullOrWhiteSpace($RawValue)) { return $null }
    $email = $null; $name = $null
    if ($RawValue -match '<([^>]+)>') { $email = $Matches[1].Trim() }
    if ($RawValue -match '^([^<]+)<') { $name = $Matches[1].Trim() }
    if (-not $email -and $RawValue -match '^[^<>]+@[^<>]+$') { $email = $RawValue.Trim() }
    if (-not $name) { $name = $RawValue }

    if ($email -and $script:IdentityByEmail.ContainsKey($email.ToLower())) { return $script:IdentityByEmail[$email.ToLower()] }
    if ($name -and $script:IdentityByName.ContainsKey($name)) { return $script:IdentityByName[$name] }
    return $null
}

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
function Should-Execute { return [bool]$Execute }

# ----------------------------------------------------------------
# Work Item Type Map: cross-process-template support
# ----------------------------------------------------------------
# Cuando el proyecto origen y destino usan process templates distintos
# (ej: Scrum en on-prem -> Agile en cloud), los tipos de work item
# del grupo de requisitos difieren. Este mapa resuelve la conversion.
#
# Mapeos conocidos entre process templates:
#   Scrum:  Product Backlog Item
#   Agile:  User Story
#   CMMI:   Requirement
#   Basic:  Issue
#
$script:ResolvedWiTypeMap = @{}

function Initialize-WorkItemTypeMap {
    Write-Status "=== Detectando Work Item Types del destino ===" -Level OK

    # Si el usuario paso un mapa explicito, usarlo
    if ($WorkItemTypeMap -and $WorkItemTypeMap.Count -gt 0) {
        $script:ResolvedWiTypeMap = $WorkItemTypeMap
        Write-Status "  WorkItemTypeMap proporcionado por usuario: $($WorkItemTypeMap.Count) entradas" -Level OK
        foreach ($k in $WorkItemTypeMap.Keys) {
            Write-Status "    '$k' -> '$($WorkItemTypeMap[$k])'" -Level INFO
        }
        return
    }

    # Auto-detectar: consultar los tipos de WI disponibles en el proyecto destino
    $typesUrl = "$TargetOrgUrl/$TargetProject/_apis/wit/workitemtypes?api-version=$ApiVersion"
    $resp = Invoke-Ado -Url $typesUrl -Pat $TargetPat
    if (Test-IsErr $resp) {
        Write-Status "  WARN: No se pudieron obtener los WI types del destino: $(Get-ErrMsg $resp)" -Level WARN
        Write-Status "  Si origen y destino usan process templates distintos, use -WorkItemTypeMap" -Level WARN
        return
    }

    $targetTypes = @($resp.value | ForEach-Object { $_.name })
    Write-Status "  Tipos disponibles en destino: $($targetTypes -join ', ')" -Level INFO

    # Detectar que tiene el destino para el grupo de requisitos
    $hasUserStory = $targetTypes -contains "User Story"
    $hasPBI       = $targetTypes -contains "Product Backlog Item"
    $hasRequirement = $targetTypes -contains "Requirement"
    $hasIssue     = $targetTypes -contains "Issue"

    # Construir mapeo automatico solo para tipos que NO existen en destino
    if (-not $hasPBI -and $hasUserStory) {
        $script:ResolvedWiTypeMap["Product Backlog Item"] = "User Story"
        Write-Status "  Auto-map: 'Product Backlog Item' -> 'User Story' (Scrum->Agile)" -Level OK
    }
    if (-not $hasUserStory -and $hasPBI) {
        $script:ResolvedWiTypeMap["User Story"] = "Product Backlog Item"
        Write-Status "  Auto-map: 'User Story' -> 'Product Backlog Item' (Agile->Scrum)" -Level OK
    }
    if (-not $hasPBI -and -not $hasUserStory -and $hasRequirement) {
        $script:ResolvedWiTypeMap["Product Backlog Item"] = "Requirement"
        $script:ResolvedWiTypeMap["User Story"] = "Requirement"
        Write-Status "  Auto-map: PBI/UserStory -> 'Requirement' (->CMMI)" -Level OK
    }
    if (-not $hasPBI -and -not $hasUserStory -and -not $hasRequirement -and $hasIssue) {
        $script:ResolvedWiTypeMap["Product Backlog Item"] = "Issue"
        $script:ResolvedWiTypeMap["User Story"] = "Issue"
        Write-Status "  Auto-map: PBI/UserStory -> 'Issue' (->Basic)" -Level OK
    }

    if ($script:ResolvedWiTypeMap.Count -eq 0) {
        Write-Status "  No se requiere mapeo de tipos (mismo process template o tipos compatibles)" -Level INFO
    }
}

function Pretty-Action {
    param([string]$Verb, [string]$Detail)
    if (Should-Execute) { Write-Status "$Verb $Detail" -Level OK }
    else { Write-Status "[DRY-RUN] $Verb $Detail" -Level DRY }
}

# ----------------------------------------------------------------
# FASE 2: Test Configurations
# ----------------------------------------------------------------
function Sync-TestConfigurations {
    Write-Status "=== FASE 2: Test Configurations ===" -Level OK
    if ($SkipConfigurations) { Write-Status "Saltado por -SkipConfigurations" -Level WARN; return }

    $srcUrl = "$SourceBaseUrl/$SourceProject/_apis/test/configurations?api-version=$SourceApiVersion"
    $resp = Invoke-Ado -Url $srcUrl -Pat $SourcePat
    if (Test-IsErr $resp) { Write-Status "Error obteniendo configs: $(Get-ErrMsg $resp)" -Level ERROR; return }
    $configs = @($resp.value)
    Write-Status "Configurations en origen: $($configs.Count)" -Level OK

    foreach ($cfg in $configs) {
        $sid = "$($cfg.id)"
        if ($script:ConfigMap.ContainsKey($sid)) {
            Write-Status "  Config '$($cfg.name)' ya mapeada -> $($script:ConfigMap[$sid])"
            continue
        }
        $body = @{
            name        = $cfg.name
            description = if ($cfg.PSObject.Properties.Match('description').Count -gt 0) { $cfg.description } else { "" }
            state       = if ($cfg.PSObject.Properties.Match('state').Count -gt 0) { $cfg.state } else { "Active" }
            values      = if ($cfg.PSObject.Properties.Match('values').Count -gt 0) { $cfg.values } else { @() }
        }
        Pretty-Action "Crear Configuration" "'$($cfg.name)'"
        if (Should-Execute) {
            $tgtUrl = "$TargetOrgUrl/$TargetProject/_apis/testplan/configurations?api-version=$ApiVersion"
            $r = Invoke-Ado -Url $tgtUrl -Method Post -Pat $TargetPat -Body $body
            if (Test-IsErr $r) {
                if ((Get-ErrMsg $r) -match 'already exists') {
                    $existing = Invoke-Ado -Url $tgtUrl -Pat $TargetPat
                    if (-not (Test-IsErr $existing) -and $existing.PSObject.Properties.Match('value').Count -gt 0) {
                        $match = @($existing.value) | Where-Object { $_.name -eq $cfg.name } | Select-Object -First 1
                        if ($match) {
                            $script:ConfigMap[$sid] = $match.id
                            Save-Map $script:ConfigMap $paths.Config
                            Write-Status "  EXISTS: Config '$($cfg.name)' ya existe (id=$($match.id)), mapeada" -Level INFO
                            continue
                        }
                    }
                }
                Write-Status "  ERROR: $(Get-ErrMsg $r)" -Level ERROR; continue
            }
            $script:ConfigMap[$sid] = $r.id
            Save-Map $script:ConfigMap $paths.Config
        }
    }
}

# ----------------------------------------------------------------
# FASE 3: Test Cases
# ----------------------------------------------------------------
function Get-SourceTestCaseIds {
    $wiql = @{
        query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$SourceProject' AND [System.WorkItemType] = 'Test Case'"
    }
    $url = "$SourceBaseUrl/$SourceProject/_apis/wit/wiql?api-version=$SourceApiVersion"
    $r = Invoke-Ado -Url $url -Method Post -Pat $SourcePat -Body $wiql
    if (Test-IsErr $r) { Write-Status "Error WIQL: $(Get-ErrMsg $r)" -Level ERROR; return @() }
    return @($r.workItems | ForEach-Object { $_.id })
}

function Get-WorkItem {
    param([string]$BaseUrl, [string]$Project, [int]$Id, [string]$Pat, [string]$ApiVer)
    $url = "$BaseUrl/$Project/_apis/wit/workitems/$Id`?`$expand=relations&api-version=$ApiVer"
    return Invoke-Ado -Url $url -Pat $Pat
}

function New-TestCaseInTarget {
    param($SourceWi)
    $fieldsToCopy = @(
        "System.Title","System.Description",
        "System.AreaPath","System.IterationPath","System.Tags",
        "Microsoft.VSTS.Common.Priority","Microsoft.VSTS.TCM.Steps",
        "Microsoft.VSTS.TCM.LocalDataSource","Microsoft.VSTS.TCM.Parameters",
        "Microsoft.VSTS.TCM.AutomatedTestName","Microsoft.VSTS.TCM.AutomatedTestId",
        "Microsoft.VSTS.TCM.AutomatedTestStorage","Microsoft.VSTS.TCM.AutomatedTestType",
        "Microsoft.VSTS.TCM.AutomationStatus"
    )
    $patch = @()
    foreach ($f in $fieldsToCopy) {
        if ($SourceWi.fields.PSObject.Properties.Match($f).Count -gt 0) {
            $val = $SourceWi.fields.$f
            if ($null -ne $val -and "$val".Length -gt 0) {
                if ($f -in @("System.AreaPath","System.IterationPath")) {
                    $val = $val -replace [regex]::Escape($SourceProject), $TargetProject
                }
                $patch += @{ op = "add"; path = "/fields/$f"; value = $val }
            }
        }
    }

    if ($script:IdentityByEmail.Count -gt 0 -or $script:IdentityByName.Count -gt 0) {
        if ($SourceWi.fields.PSObject.Properties.Match('System.AssignedTo').Count -gt 0) {
            $rawAssigned = $SourceWi.fields."System.AssignedTo"
            $resolved = $null
            if ($rawAssigned -is [string]) {
                $resolved = Resolve-TargetIdentityString -RawValue $rawAssigned
            } else {
                $resolved = Resolve-TargetIdentity -SourceIdentity $rawAssigned
            }
            if ($resolved -and $resolved.uniqueName) {
                $patch += @{ op = "add"; path = "/fields/System.AssignedTo"; value = $resolved.uniqueName }
            }
        }
    }

    $patch += @{ op = "add"; path = "/fields/System.History"; value = "Migrado desde $SourceBaseUrl/$SourceProject WorkItem $($SourceWi.id)" }

    $url = "$TargetOrgUrl/$TargetProject/_apis/wit/workitems/`$Test Case?api-version=$ApiVersion"
    $body = ($patch | ConvertTo-Json -Depth 20 -Compress)
    return Invoke-Ado -Url $url -Method Post -Pat $TargetPat -Body $body -ContentType "application/json-patch+json"
}

function Sync-TestCases {
    Write-Status "=== FASE 3: Test Cases ===" -Level OK
    if ($SkipTestCases) {
        Write-Status "Saltado por -SkipTestCases (mapping con $($script:TestCaseMap.Count) entradas)" -Level WARN
        return
    }
    $ids = Get-SourceTestCaseIds
    Write-Status "Test Cases en origen: $($ids.Count)" -Level OK

    $i = 0
    foreach ($sid in $ids) {
        $i++
        $sidStr = "$sid"
        if ($script:TestCaseMap.ContainsKey($sidStr)) { continue }

        $wi = Get-WorkItem -BaseUrl $SourceBaseUrl -Project $SourceProject -Id $sid -Pat $SourcePat -ApiVer $SourceApiVersion
        if (Test-IsErr $wi) { Write-Status "  [$i] Error GET WI $sid : $(Get-ErrMsg $wi)" -Level ERROR; continue }

        $title = $wi.fields."System.Title"
        Pretty-Action "Crear Test Case" "[$i/$($ids.Count)] sourceId=$sid title='$title'"

        if (Should-Execute) {
            $r = New-TestCaseInTarget -SourceWi $wi
            if (Test-IsErr $r) { Write-Status "  ERROR: $(Get-ErrMsg $r)" -Level ERROR; continue }
            $script:TestCaseMap[$sidStr] = $r.id
            if (($i % 25) -eq 0) { Save-Map $script:TestCaseMap $paths.TestCase }
        }
    }
    if (Should-Execute) { Save-Map $script:TestCaseMap $paths.TestCase }
}

# ----------------------------------------------------------------
# FASE 3.5: Requirement Work Items
# ----------------------------------------------------------------
# Las RequirementTestSuites referencian work items del grupo de requisitos
# (User Story, PBI, Feature, Bug, etc.) via requirementId.
# Si estos work items no existen en el destino, la creacion de la suite falla.
# Esta fase descubre los requirementIds de todas las suites y los migra.

function Get-AllRequirementIdsFromSource {
    Write-Status "  Descubriendo requirementIds de todas las suites..." -Level INFO

    $reqIds = @{}
    $plansUrl = "$SourceBaseUrl/$SourceProject/_apis/test/plans?api-version=$SourceApiVersion"
    $plansResp = Invoke-Ado -Url $plansUrl -Pat $SourcePat
    if (Test-IsErr $plansResp) { Write-Status "  Error listando planes: $(Get-ErrMsg $plansResp)" -Level ERROR; return @() }

    $plans = @($plansResp.value | Where-Object { $_.name -like $PlanFilter })
    foreach ($plan in $plans) {
        $suitesUrl = "$SourceBaseUrl/$SourceProject/_apis/test/plans/$($plan.id)/suites?api-version=$SourceApiVersion"
        $suitesResp = Invoke-Ado -Url $suitesUrl -Pat $SourcePat
        if (Test-IsErr $suitesResp) { continue }

        foreach ($suite in @($suitesResp.value)) {
            if ($suite.PSObject.Properties.Match('suiteType').Count -gt 0 -and
                $suite.suiteType -eq "RequirementTestSuite" -and
                $suite.PSObject.Properties.Match('requirementId').Count -gt 0 -and
                $suite.requirementId) {
                $reqIds["$($suite.requirementId)"] = $suite.requirementId
            }
        }
    }

    $result = @($reqIds.Values)
    Write-Status "  RequirementIds unicos encontrados: $($result.Count)" -Level INFO
    return $result
}

function New-RequirementInTarget {
    param($SourceWi)

    # Detectar el tipo de work item del requisito
    $wiType = "User Story"
    if ($SourceWi.fields.PSObject.Properties.Match('System.WorkItemType').Count -gt 0) {
        $wiType = $SourceWi.fields."System.WorkItemType"
    }

    # Aplicar mapping de tipos entre process templates (ej: Scrum->Agile)
    if ($script:ResolvedWiTypeMap.ContainsKey($wiType)) {
        $mappedType = $script:ResolvedWiTypeMap[$wiType]
        Write-Status "    Tipo mapeado: '$wiType' -> '$mappedType'" -Level INFO
        $wiType = $mappedType
    }

    $fieldsToCopy = @(
        "System.Title","System.Description",
        "System.AreaPath","System.IterationPath","System.Tags",
        "Microsoft.VSTS.Common.Priority",
        "Microsoft.VSTS.Common.AcceptanceCriteria",
        "Microsoft.VSTS.Scheduling.StoryPoints",
        "Microsoft.VSTS.Scheduling.Effort",
        "Microsoft.VSTS.Common.BusinessValue"
    )

    $patch = @()
    foreach ($f in $fieldsToCopy) {
        if ($SourceWi.fields.PSObject.Properties.Match($f).Count -gt 0) {
            $val = $SourceWi.fields.$f
            if ($null -ne $val -and "$val".Length -gt 0) {
                if ($f -in @("System.AreaPath","System.IterationPath")) {
                    $val = $val -replace [regex]::Escape($SourceProject), $TargetProject
                }
                $patch += @{ op = "add"; path = "/fields/$f"; value = $val }
            }
        }
    }

    $patch += @{ op = "add"; path = "/fields/System.History"; value = "Migrado como requisito de TestPlan desde $SourceBaseUrl/$SourceProject WorkItem $($SourceWi.id)" }

    # Escapar el tipo de work item para la URL
    $wiTypeEncoded = [Uri]::EscapeDataString($wiType)
    $url = "$TargetOrgUrl/$TargetProject/_apis/wit/workitems/`$$wiTypeEncoded`?api-version=$ApiVersion"
    $body = ($patch | ConvertTo-Json -Depth 20 -Compress)
    return Invoke-Ado -Url $url -Method Post -Pat $TargetPat -Body $body -ContentType "application/json-patch+json"
}

function Sync-Requirements {
    Write-Status "=== FASE 3.5: Requirement Work Items ===" -Level OK
    if ($SkipRequirements) {
        Write-Status "Saltado por -SkipRequirements (mapping con $($script:RequirementMap.Count) entradas)" -Level WARN
        return
    }

    $reqIds = Get-AllRequirementIdsFromSource
    if ($reqIds.Count -eq 0) {
        Write-Status "  No hay RequirementTestSuites, nada que migrar" -Level INFO
        return
    }

    $i = 0
    foreach ($reqId in $reqIds) {
        $i++
        $ridStr = "$reqId"

        # Si ya esta mapeado (por ejecucion previa o por TestCaseMap), saltar
        if ($script:RequirementMap.ContainsKey($ridStr)) {
            Write-Status "  Requisito $ridStr ya mapeado -> $($script:RequirementMap[$ridStr])"
            continue
        }
        if ($script:TestCaseMap.ContainsKey($ridStr)) {
            $script:RequirementMap[$ridStr] = $script:TestCaseMap[$ridStr]
            Write-Status "  Requisito $ridStr encontrado en TestCaseMap -> $($script:TestCaseMap[$ridStr])"
            continue
        }

        $wi = Get-WorkItem -BaseUrl $SourceBaseUrl -Project $SourceProject -Id $reqId -Pat $SourcePat -ApiVer $SourceApiVersion
        if (Test-IsErr $wi) {
            Write-Status "  [$i] Error GET Requirement WI $reqId : $(Get-ErrMsg $wi)" -Level ERROR
            continue
        }

        $title = $wi.fields."System.Title"
        $wiType = if ($wi.fields.PSObject.Properties.Match('System.WorkItemType').Count -gt 0) { $wi.fields."System.WorkItemType" } else { "Unknown" }
        Pretty-Action "Crear Requirement" "[$i/$($reqIds.Count)] sourceId=$reqId type=$wiType title='$title'"

        if (Should-Execute) {
            $r = New-RequirementInTarget -SourceWi $wi
            if (Test-IsErr $r) {
                Write-Status "  ERROR creando requisito $reqId : $(Get-ErrMsg $r)" -Level ERROR
                continue
            }
            $script:RequirementMap[$ridStr] = $r.id
            Write-Status "  Requisito migrado: $ridStr -> $($r.id)" -Level OK
        }
    }

    if (Should-Execute) { Save-Map $script:RequirementMap $paths.Requirement }
    Write-Status "  Requirements mapeados: $($script:RequirementMap.Count)" -Level OK
}

# ----------------------------------------------------------------
# FASE 4: Test Plans
# ----------------------------------------------------------------
function Sync-TestPlans {
    Write-Status "=== FASE 4: Test Plans ===" -Level OK
    $url = "$SourceBaseUrl/$SourceProject/_apis/test/plans?api-version=$SourceApiVersion"
    $resp = Invoke-Ado -Url $url -Pat $SourcePat
    if (Test-IsErr $resp) { Write-Status "Error plans: $(Get-ErrMsg $resp)" -Level ERROR; return @() }

    $plans = @($resp.value | Where-Object { $_.name -like $PlanFilter })
    Write-Status "Plans a migrar: $($plans.Count)" -Level OK

    $created = @()
    foreach ($plan in $plans) {
        $sid = "$($plan.id)"
        if ($script:PlanMap.ContainsKey($sid)) {
            Write-Status "  Plan '$($plan.name)' ya migrado -> $($script:PlanMap[$sid])"
            $created += @{ Source = $plan; TargetId = $script:PlanMap[$sid] }
            continue
        }

        $area = if ($plan.PSObject.Properties.Match('area').Count -gt 0 -and $null -ne $plan.area -and $plan.area.PSObject.Properties.Match('name').Count -gt 0) { $plan.area.name } else { $TargetProject }
        $iteration = if ($plan.PSObject.Properties.Match('iteration').Count -gt 0) { $plan.iteration } else { $TargetProject }
        $area = $area -replace [regex]::Escape($SourceProject), $TargetProject
        $iteration = $iteration -replace [regex]::Escape($SourceProject), $TargetProject

        $body = @{
            name        = $plan.name
            description = if ($plan.PSObject.Properties.Match('description').Count -gt 0) { $plan.description } else { "" }
            areaPath    = $area
            iteration   = $iteration
            state       = if ($plan.PSObject.Properties.Match('state').Count -gt 0) { $plan.state } else { "Active" }
        }

        if ($plan.PSObject.Properties.Match('startDate').Count -gt 0 -and $plan.startDate) { $body.startDate = $plan.startDate }
        if ($plan.PSObject.Properties.Match('endDate').Count -gt 0 -and $plan.endDate) { $body.endDate = $plan.endDate }

        if ($plan.PSObject.Properties.Match('owner').Count -gt 0 -and $plan.owner) {
            $resolvedOwner = Resolve-TargetIdentity -SourceIdentity $plan.owner
            if ($resolvedOwner -and $resolvedOwner.uniqueName) {
                $body.owner = @{ uniqueName = $resolvedOwner.uniqueName; displayName = $resolvedOwner.displayName }
            }
        }

        Pretty-Action "Crear Plan" "'$($plan.name)' (sourceId=$($plan.id))"

        if (Should-Execute) {
            $tgtUrl = "$TargetOrgUrl/$TargetProject/_apis/testplan/plans?api-version=$ApiVersion"
            $r = Invoke-Ado -Url $tgtUrl -Method Post -Pat $TargetPat -Body $body
            if (Test-IsErr $r) { Write-Status "  ERROR: $(Get-ErrMsg $r)" -Level ERROR; continue }
            $script:PlanMap[$sid] = $r.id
            Save-Map $script:PlanMap $paths.Plan
            $created += @{ Source = $plan; TargetId = $r.id }
        } else {
            $created += @{ Source = $plan; TargetId = $null }
        }
    }
    return ,$created
}

# ----------------------------------------------------------------
# FASE 5 + 6: Test Suites + Test Cases en suites
# ----------------------------------------------------------------
function Get-SuitesForPlan {
    param([int]$PlanId)
    $url = "$SourceBaseUrl/$SourceProject/_apis/test/plans/$PlanId/suites?api-version=$SourceApiVersion&`$expand=children"
    $r = Invoke-Ado -Url $url -Pat $SourcePat
    if (Test-IsErr $r) { Write-Status "  ERROR Get-SuitesForPlan: $(Get-ErrMsg $r)" -Level ERROR; return @() }
    $flat = @($r.value)

    $allSuites = @()
    $queue = New-Object System.Collections.Queue
    foreach ($s in $flat) { $queue.Enqueue($s) }

    while ($queue.Count -gt 0) {
        $s = $queue.Dequeue()
        $allSuites += $s

        if ($s.PSObject.Properties.Match('children').Count -gt 0 -and $null -ne $s.children) {
            foreach ($child in @($s.children)) {
                $queue.Enqueue($child)
            }
        }

        if ($s.PSObject.Properties.Match('hasChildren').Count -gt 0 -and $s.hasChildren -and
            (-not ($s.PSObject.Properties.Match('children').Count -gt 0 -and $null -ne $s.children))) {
            $childUrl = "$SourceBaseUrl/$SourceProject/_apis/test/plans/$PlanId/suites/$($s.id)?api-version=$SourceApiVersion&includeChildSuites=true"
            $cr = Invoke-Ado -Url $childUrl -Pat $SourcePat
            if (-not (Test-IsErr $cr) -and $cr.PSObject.Properties.Match('children').Count -gt 0 -and $null -ne $cr.children) {
                foreach ($child in @($cr.children)) {
                    $queue.Enqueue($child)
                }
            }
        }
    }

    foreach ($s in $allSuites) {
        $parentId = if ($s.PSObject.Properties.Match('parentSuite').Count -gt 0 -and $s.parentSuite) { $s.parentSuite.id } else { "null" }
        $type = if ($s.PSObject.Properties.Match('suiteType').Count -gt 0) { $s.suiteType } else { "Unknown" }
        Write-Status "  Suite: id=$($s.id) name='$($s.name)' type=$type parent=$parentId" -Level INFO
    }

    return $allSuites
}

function Get-SuiteTestCaseIds {
    param([int]$PlanId, [int]$SuiteId)
    $url = "$SourceBaseUrl/$SourceProject/_apis/test/plans/$PlanId/suites/$SuiteId/testcases?api-version=$SourceApiVersion"
    $r = Invoke-Ado -Url $url -Pat $SourcePat
    if (Test-IsErr $r) { return @() }
    return @($r.value | ForEach-Object { $_.testCase.id })
}

function Resolve-RequirementId {
    # Busca el requirementId en todos los mapas disponibles.
    # Retorna el ID destino o $null si no se encuentra.
    param([int]$SourceReqId)
    $ridStr = "$SourceReqId"

    if ($script:RequirementMap.ContainsKey($ridStr)) {
        return $script:RequirementMap[$ridStr]
    }
    if ($script:TestCaseMap.ContainsKey($ridStr)) {
        return $script:TestCaseMap[$ridStr]
    }
    return $null
}

function New-Suite {
    param([int]$TargetPlanId, [int]$TargetParentId, $SourceSuite)

    $type = if ($SourceSuite.PSObject.Properties.Match('suiteType').Count -gt 0) { $SourceSuite.suiteType } else { "StaticTestSuite" }
    $fallbackToStatic = $false

    $body = @{
        suiteType   = $type
        name        = $SourceSuite.name
        parentSuite = @{ id = $TargetParentId }
    }

    if ($type -eq "DynamicTestSuite" -and $SourceSuite.PSObject.Properties.Match('queryString').Count -gt 0) {
        $body.queryString = $SourceSuite.queryString -replace [regex]::Escape("'$SourceProject'"), "'$TargetProject'"
    }

    if ($type -eq "RequirementTestSuite" -and $SourceSuite.PSObject.Properties.Match('requirementId').Count -gt 0) {
        $resolvedReqId = Resolve-RequirementId -SourceReqId $SourceSuite.requirementId
        if ($null -ne $resolvedReqId) {
            $body.requirementId = $resolvedReqId
        } else {
            # FALLBACK: el requisito no existe en destino, convertir a StaticTestSuite
            Write-Status "    FALLBACK: Convirtiendo RequirementTestSuite '$($SourceSuite.name)' a StaticTestSuite (requirementId=$($SourceSuite.requirementId) no tiene mapping en destino)" -Level WARN
            $body.suiteType = "StaticTestSuite"
            $fallbackToStatic = $true
        }
    }

    $url = "$TargetOrgUrl/$TargetProject/_apis/testplan/Plans/$TargetPlanId/suites?api-version=$ApiVersion"
    $result = Invoke-Ado -Url $url -Method Post -Pat $TargetPat -Body $body

    # Retornar resultado con flag de fallback para que el caller sepa que debe
    # asociar test cases manualmente (las RequirementTestSuites lo hacen automatico)
    if (-not (Test-IsErr $result)) {
        $result | Add-Member -NotePropertyName "_fallbackToStatic" -NotePropertyValue $fallbackToStatic -Force
    }

    return $result
}

function Add-TestCasesToSuite {
    param([int]$TargetPlanId, [int]$TargetSuiteId, [int[]]$TargetTcIds)
    if ($TargetTcIds.Count -eq 0) { return }

    $payload = @($TargetTcIds | Sort-Object -Unique | ForEach-Object { @{ workItem = @{ id = $_ } } })
    $url = "$TargetOrgUrl/$TargetProject/_apis/testplan/Plans/$TargetPlanId/Suites/$TargetSuiteId/TestCase?api-version=$ApiVersion"
    return Invoke-Ado -Url $url -Method Post -Pat $TargetPat -Body $payload
}

function Sync-SuitesAndTestCases {
    param($PlansCreated)

    Write-Status "=== FASE 5/6: Suites + asociacion Test Cases ===" -Level OK

    foreach ($entry in $PlansCreated) {
        $plan = $entry.Source
        $tgtPlanId = $entry.TargetId
        Write-Status "Plan '$($plan.name)' (source=$($plan.id) target=$tgtPlanId)"

        $suites = @(Get-SuitesForPlan -PlanId $plan.id)
        Write-Status "  Suites obtenidas del origen: $($suites.Count)" -Level INFO

        if ($suites.Count -eq 0) {
            Write-Status "  Sin suites, saltando plan" -Level WARN
            continue
        }

        # Suite raiz
        $root = $suites | Where-Object {
            -not ($_.PSObject.Properties.Match('parentSuite').Count -gt 0 -and $_.parentSuite)
        } | Select-Object -First 1
        if (-not $root) { $root = $suites[0] }
        Write-Status "  Suite raiz: '$($root.name)' (id=$($root.id))" -Level INFO

        # Mapear root a la suite raiz del plan destino
        $rootKey = "$($plan.id)/$($root.id)"
        if ($tgtPlanId -and -not $script:SuiteMap.ContainsKey($rootKey)) {
            $rUrl = "$TargetOrgUrl/$TargetProject/_apis/testplan/Plans/$tgtPlanId/suites?api-version=$ApiVersion"
            Write-Status "  GET suite raiz destino: $rUrl" -Level INFO
            $rr = Invoke-Ado -Url $rUrl -Pat $TargetPat
            $isErr = Test-IsErr $rr
            Write-Status "  Respuesta suite raiz: isErr=$isErr" -Level INFO

            if ($isErr) {
                Write-Status "  ERROR detail: $(Get-ErrMsg $rr)" -Level ERROR
            } elseif ($rr.PSObject.Properties.Match('value').Count -gt 0) {
                $rrValues = @($rr.value)
                Write-Status "  Suites en destino: $($rrValues.Count)" -Level INFO
                if ($rrValues.Count -gt 0) {
                    $script:SuiteMap[$rootKey] = ($rrValues | Sort-Object id | Select-Object -First 1).id
                    Write-Status "  Suite raiz mapeada: $rootKey -> $($script:SuiteMap[$rootKey])" -Level OK
                } else {
                    Write-Status "  ERROR: Plan destino $tgtPlanId no tiene suites" -Level ERROR
                }
            } elseif ($rr.PSObject.Properties.Match('id').Count -gt 0) {
                $script:SuiteMap[$rootKey] = $rr.id
                Write-Status "  Suite raiz mapeada (directo): $rootKey -> $($rr.id)" -Level OK
            } else {
                Write-Status "  ERROR: Respuesta inesperada para suites del plan destino $tgtPlanId" -Level ERROR
                Write-Status "  Response keys: $($rr.PSObject.Properties.Name -join ', ')" -Level INFO
            }
        }

        # BFS por parentSuite.id
        $byParent = @{}
        foreach ($s in $suites) {
            $parentKey = if ($s.PSObject.Properties.Match('parentSuite').Count -gt 0 -and $s.parentSuite) { "$($s.parentSuite.id)" } else { "ROOT" }
            if (-not $byParent.ContainsKey($parentKey)) { $byParent[$parentKey] = @() }
            $byParent[$parentKey] += $s
        }

        Write-Status "  Grupos por padre: $($byParent.Keys.Count) (claves: $($byParent.Keys -join ', '))" -Level INFO

        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($root)

        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $curKey = "$($plan.id)/$($current.id)"
            $tgtCurId = $script:SuiteMap[$curKey]

            Write-Status "  Procesando suite '$($current.name)' (id=$($current.id)) -> target=$tgtCurId" -Level INFO

            # Asociar test cases a la suite actual
            $sourceTcIds = @(Get-SuiteTestCaseIds -PlanId $plan.id -SuiteId $current.id)
            if ($sourceTcIds.Count -gt 0) {
                $tgtTcIds = @()
                foreach ($tc in $sourceTcIds) {
                    if ($script:TestCaseMap.ContainsKey("$tc")) { $tgtTcIds += [int]$script:TestCaseMap["$tc"] }
                    else { Write-Status "    TC source $tc no mapeado, se omite" -Level WARN }
                }
                Pretty-Action "Asociar TCs a suite" "suite='$($current.name)' count=$($tgtTcIds.Count)"
                if (Should-Execute -and $tgtCurId -and $tgtTcIds.Count -gt 0) {
                    $r = Add-TestCasesToSuite -TargetPlanId $tgtPlanId -TargetSuiteId $tgtCurId -TargetTcIds $tgtTcIds
                    if (Test-IsErr $r) { Write-Status "    ERROR asociar TCs: $(Get-ErrMsg $r)" -Level ERROR }
                    else { Write-Status "    TCs asociados OK ($($tgtTcIds.Count))" -Level OK }
                }
            }

            # Crear hijas con try/catch individual para resiliencia
            $children = @()
            if ($byParent.ContainsKey("$($current.id)")) { $children = @($byParent["$($current.id)"]) }
            Write-Status "  Hijas de '$($current.name)': $($children.Count)" -Level INFO

            foreach ($child in $children) {
                try {
                    $childKey = "$($plan.id)/$($child.id)"
                    if ($script:SuiteMap.ContainsKey($childKey)) {
                        Write-Status "    Suite '$($child.name)' ya mapeada -> $($script:SuiteMap[$childKey])" -Level INFO
                        $queue.Enqueue($child)
                        continue
                    }

                    $childType = if ($child.PSObject.Properties.Match('suiteType').Count -gt 0) { $child.suiteType } else { "StaticTestSuite" }
                    Pretty-Action "Crear Suite" "'$($child.name)' type=$childType parent=$($current.name)"

                    if (Should-Execute -and $tgtCurId) {
                        $r = New-Suite -TargetPlanId $tgtPlanId -TargetParentId $tgtCurId -SourceSuite $child
                        if (Test-IsErr $r) {
                            Write-Status "    ERROR crear suite '$($child.name)': $(Get-ErrMsg $r)" -Level ERROR
                            # Resiliencia: encolar la suite de todas formas para
                            # que sus hijas se procesen (aunque sin target, se loguearan errores)
                            $queue.Enqueue($child)
                            continue
                        }

                        $newId = if ($r.PSObject.Properties.Match('value').Count -gt 0 -and @($r.value).Count -gt 0) { $r.value[0].id } else { $r.id }
                        $script:SuiteMap[$childKey] = $newId
                        Write-Status "    Suite creada: $childKey -> $newId" -Level OK
                        Save-Map $script:SuiteMap $paths.Suite

                        # Si la suite fue convertida de RequirementTestSuite a StaticTestSuite,
                        # los test cases NO se asocian automaticamente (las Requirement suites
                        # normalmente los heredan del link requisito->test case).
                        # Debemos asociarlos explicitamente.
                        $wasFallback = $false
                        if ($r.PSObject.Properties.Match('_fallbackToStatic').Count -gt 0) {
                            $wasFallback = $r._fallbackToStatic
                        }
                        if ($wasFallback) {
                            Write-Status "    Suite fue fallback a Static, asociando TCs explicitamente..." -Level WARN
                            $childTcIds = @(Get-SuiteTestCaseIds -PlanId $plan.id -SuiteId $child.id)
                            if ($childTcIds.Count -gt 0) {
                                $tgtChildTcIds = @()
                                foreach ($tc in $childTcIds) {
                                    if ($script:TestCaseMap.ContainsKey("$tc")) { $tgtChildTcIds += [int]$script:TestCaseMap["$tc"] }
                                }
                                if ($tgtChildTcIds.Count -gt 0) {
                                    $tcr = Add-TestCasesToSuite -TargetPlanId $tgtPlanId -TargetSuiteId $newId -TargetTcIds $tgtChildTcIds
                                    if (Test-IsErr $tcr) { Write-Status "    ERROR asociar TCs en fallback: $(Get-ErrMsg $tcr)" -Level ERROR }
                                    else { Write-Status "    TCs asociados OK en fallback ($($tgtChildTcIds.Count))" -Level OK }
                                }
                            }
                        }
                    }

                    $queue.Enqueue($child)

                } catch {
                    Write-Status "    EXCEPCION procesando suite '$($child.name)': $($_.Exception.Message)" -Level ERROR
                    # Resiliencia: seguir con las demas hermanas
                    $queue.Enqueue($child)
                }
            }
        }

        Save-Map $script:SuiteMap $paths.Suite
    }
}

# ----------------------------------------------------------------
# FASE 7: Export Test Runs / Results historicos a JSON
# ----------------------------------------------------------------
function Export-TestRunsHistory {
    Write-Status "=== FASE 7: Export Test Runs (historico, no se recrean) ===" -Level OK
    if ($SkipRunsExport) { Write-Status "Saltado por -SkipRunsExport" -Level WARN; return }

    $runsDir = Join-Path $OutputDir "test-runs-export"
    New-Item -ItemType Directory -Path $runsDir -Force | Out-Null

    $url = "$SourceBaseUrl/$SourceProject/_apis/test/runs?api-version=$SourceApiVersion&`$top=1000"
    $r = Invoke-Ado -Url $url -Pat $SourcePat
    if (Test-IsErr $r) { Write-Status "Error listando runs: $(Get-ErrMsg $r)" -Level ERROR; return }

    $runs = @($r.value)
    Write-Status "Runs en origen: $($runs.Count) (exportando)" -Level OK

    foreach ($run in $runs) {
        $runFile = Join-Path $runsDir "run_$($run.id).json"
        $resultsUrl = "$SourceBaseUrl/$SourceProject/_apis/test/runs/$($run.id)/results?api-version=$SourceApiVersion"
        $rr = Invoke-Ado -Url $resultsUrl -Pat $SourcePat
        $results = if (Test-IsErr $rr) { @() } else { @($rr.value) }

        $payload = [ordered]@{
            run     = $run
            results = $results
        }
        ($payload | ConvertTo-Json -Depth 30) | Out-File -FilePath $runFile -Encoding UTF8
    }

    Write-Status "Runs exportados a: $runsDir" -Level OK
}

# ----------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------
$_toolName    = "Migrate-TestPlans"
$_toolVersion = "1.1.0"
$_toolUpdate  = "2025-05-08"

Write-Host ""
Write-Host " ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Magenta
Write-Host " │                                                          │" -ForegroundColor Magenta
Write-Host " │  ■ ■  $_toolName v$_toolVersion                     │" -ForegroundColor Magenta
Write-Host " │       Last update: $_toolUpdate                         │" -ForegroundColor Magenta
Write-Host " │       ADO Server -> ADO Services Cloud                   │" -ForegroundColor Magenta
Write-Host " │                                                          │" -ForegroundColor Magenta
Write-Host " └──────────────────────────────────────────────────────────┘" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Source : $SourceBaseUrl / $SourceProject" -ForegroundColor Cyan
Write-Host "  Target : $TargetOrgUrl / $TargetProject" -ForegroundColor Cyan
Write-Host "  Modo   : $(if (Should-Execute) { 'EXECUTE (real)' } else { 'DRY-RUN' })" -ForegroundColor Cyan
Write-Host "  Output : $OutputDir" -ForegroundColor Cyan
Write-Host ""

if (-not (Should-Execute)) {
    Write-Status "Modo DRY-RUN: no se realizaran cambios en destino. Use -Execute para aplicar." -Level WARN
}

Initialize-WorkItemTypeMap

Sync-TestConfigurations
Sync-TestCases
Sync-Requirements

$plansCreated = Sync-TestPlans
if ($plansCreated -and $plansCreated.Count -gt 0) {
    Sync-SuitesAndTestCases -PlansCreated $plansCreated
}

Export-TestRunsHistory

# Persistir mappings finales
Save-Map $script:TestCaseMap    $paths.TestCase
Save-Map $script:RequirementMap $paths.Requirement
Save-Map $script:ConfigMap      $paths.Config
Save-Map $script:PlanMap        $paths.Plan
Save-Map $script:SuiteMap       $paths.Suite

Write-Host ""
Write-Status "=== RESUMEN ===" -Level OK
Write-Status "Test Cases mapeados    : $($script:TestCaseMap.Count)" -Level OK
Write-Status "Requirements mapeados  : $($script:RequirementMap.Count)" -Level OK
Write-Status "Configs mapeadas       : $($script:ConfigMap.Count)" -Level OK
Write-Status "Plans mapeados         : $($script:PlanMap.Count)" -Level OK
Write-Status "Suites mapeadas        : $($script:SuiteMap.Count)" -Level OK
Write-Status "Mappings en            : $OutputDir" -Level OK
Write-Status "Log                    : $script:LogFilePath" -Level OK
Write-Host ""