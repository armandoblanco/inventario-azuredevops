<#
.SYNOPSIS
    Audit-TfvcRepos.ps1
    Inventario de repositorios TFVC en Azure DevOps Server OnPrem.

.DESCRIPTION
    Consulta las APIs REST de TFVC para cada proyecto de la collection y extrae:
      1. Si el proyecto tiene contenido TFVC (vs solo Git)
      2. Branches TFVC y su estructura
      3. Ultimo changeset (fecha, autor)
      4. Conteo de archivos y carpetas en el root
      5. Pipelines que apuntan a TFVC
    Genera CSV y JSON consolidado.

.PARAMETER AdoBaseUrl
    URL base de la collection. Si no se provee, se lee $env:ADO_BASE (desde .env).

.PARAMETER ProjectFilter
    Filtro opcional por nombre de proyecto (wildcard). Default: * (todos)

.PARAMETER OutputDir
    Directorio de salida para reportes. Default: .\tfvc-audit

.PARAMETER PatToken
    PAT de ADO Server. Si no se provee, se lee $env:ADO_PAT (desde .env).
    Si no hay PAT, usa credenciales default (NTLM/Kerberos).

.PARAMETER EnvFile
    Ruta al archivo .env con la configuracion. Default: ./.env (junto al script).

.PARAMETER InactiveMonths
    Meses sin changesets para clasificar como inactivo. Default: 12

.PARAMETER ApiVersion
    Version de la API REST. Default: 5.0 (compatible con ADO Server 2019+)

.EXAMPLE
    # Usando .env (ADO_BASE y ADO_PAT)
    .\Audit-TfvcRepos.ps1

.EXAMPLE
    .\Audit-TfvcRepos.ps1 -ProjectFilter "TP*"

.EXAMPLE
    .\Audit-TfvcRepos.ps1 -AdoBaseUrl "https://server/tfs/Collection" -PatToken $env:ADO_PAT

.NOTES
    Requiere: Conectividad a ADO Server, PowerShell 5.1+
    Operacion: Solo lectura. No modifica nada en el servidor.
#>

[CmdletBinding()]
param(
    [string]$AdoBaseUrl,

    [string]$ProjectFilter = "*",

    [string]$OutputDir = ".\tfvc-audit",

    [string]$PatToken,

    [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),

    [int]$InactiveMonths = 12,

    [string]$ApiVersion = "5.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ----------------------------------------------------------------
# CARGA DE .env (mismo formato que test-migrate.ps1)
# ----------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "INFO: No se encontro archivo .env en '$Path'. Se usaran variables de entorno actuales." -ForegroundColor DarkYellow
        return
    }
    Write-Host "INFO: Cargando configuracion desde $Path" -ForegroundColor DarkCyan
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

# Resolver parametros desde .env / variables de entorno si no vinieron por CLI
if (-not $AdoBaseUrl) { $AdoBaseUrl = $env:ADO_BASE }
if (-not $PatToken)   { $PatToken   = $env:ADO_PAT }

if (-not $AdoBaseUrl) {
    Write-Host "ERROR: Falta AdoBaseUrl. Pasa -AdoBaseUrl o define ADO_BASE en .env" -ForegroundColor Red
    exit 1
}
if (-not $PatToken) {
    Write-Host "WARN: No se definio ADO_PAT. Se usaran credenciales Windows (NTLM/Kerberos)." -ForegroundColor Yellow
}

# ----------------------------------------------------------------
# Funciones auxiliares
# ----------------------------------------------------------------

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "OK"      { "Green" }
        default   { "White" }
    }
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
}

function Invoke-AdoApi {
    param(
        [string]$Url,
        [string]$Pat
    )

    $headers = @{}
    if ($Pat) {
        $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        $headers["Authorization"] = "Basic $base64"
    }

    $params = @{
        Uri         = $Url
        Method      = "Get"
        Headers     = $headers
        ContentType = "application/json"
    }
    if (-not $Pat) {
        $params["UseDefaultCredentials"] = $true
    }

    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $statusCode = "Unknown"
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        return [PSCustomObject]@{
            _error     = $true
            _statusCode = $statusCode
            _message   = $_.Exception.Message
        }
    }
}

function Test-IsApiError {
    param($Response)
    if ($null -eq $Response) { return $true }
    if ($Response.PSObject.Properties.Match('_error').Count -gt 0) {
        return [bool]$Response._error
    }
    return $false
}

function Get-ApiErrorMessage {
    param($Response)
    if ($null -eq $Response) { return "Null response" }
    if ($Response.PSObject.Properties.Match('_message').Count -gt 0) {
        return $Response._message
    }
    return "Unknown error"
}

function Get-ApiErrorStatusCode {
    param($Response)
    if ($null -eq $Response) { return "Unknown" }
    if ($Response.PSObject.Properties.Match('_statusCode').Count -gt 0) {
        return $Response._statusCode
    }
    return "Unknown"
}

function Get-AllProjects {
    param([string]$BaseUrl, [string]$Pat, [string]$ApiVer)

    $allProjects = @()
    $skip = 0
    $top = 100

    do {
        $url = "$BaseUrl/_apis/projects?`$top=$top&`$skip=$skip&api-version=$ApiVer"
        $response = Invoke-AdoApi -Url $url -Pat $Pat

        if (Test-IsApiError $response) {
            Write-Status "Error obteniendo proyectos: $(Get-ApiErrorMessage $response)" -Level "ERROR"
            return $allProjects
        }

        $batch = @($response.value)
        $allProjects += $batch
        $skip += $top
    } while ($batch.Count -eq $top)

    return $allProjects
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Inventario TFVC - Azure DevOps Server OnPrem" -ForegroundColor Cyan
Write-Host "  Collection: $AdoBaseUrl" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Crear directorio de salida
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Obtener todos los proyectos
Write-Status "Obteniendo lista de proyectos..."
$allProjects = @(Get-AllProjects -BaseUrl $AdoBaseUrl -Pat $PatToken -ApiVer $ApiVersion)
Write-Status "Proyectos en la collection: $($allProjects.Count)"

if ($ProjectFilter -ne "*") {
    $allProjects = @($allProjects | Where-Object { $_.name -like $ProjectFilter })
    Write-Status "Proyectos despues de filtro '$ProjectFilter': $($allProjects.Count)"
}

if ($allProjects.Count -eq 0) {
    Write-Status "No se encontraron proyectos." -Level "WARN"
    exit 0
}

# Resultados
$auditResults = @()
$allBranches = @()
$allPipelinesTfvc = @()
$projectIndex = 0

$cutoffDate = (Get-Date).AddMonths(-$InactiveMonths)

foreach ($project in $allProjects) {
    $projectIndex++
    $projectName = $project.name
    $projectId = $project.id

    Write-Host ""
    Write-Status "[$projectIndex/$($allProjects.Count)] $projectName" -Level "INFO"

    # ---- 1. Verificar si tiene TFVC ----
    Write-Status "  Verificando contenido TFVC..."
    $tfvcUrl = "$AdoBaseUrl/$projectName/_apis/tfvc/items?scopePath=`$/$projectName&recursionLevel=OneLevel&api-version=$ApiVersion"
    $tfvcItems = Invoke-AdoApi -Url $tfvcUrl -Pat $PatToken

    $hasTfvc = $false
    $fileCount = 0
    $folderCount = 0

    if (-not (Test-IsApiError $tfvcItems)) {
        $items = @($tfvcItems.value)
        if ($items.Count -gt 0) {
            $hasTfvc = $true
            # El primer item es el root folder, excluirlo del conteo
            $childItems = @($items | Where-Object { $_.path -ne "`$/$projectName" })
            $fileCount = @($childItems | Where-Object { -not $_.isFolder }).Count
            $folderCount = @($childItems | Where-Object { $_.isFolder }).Count
            Write-Status "  TFVC encontrado: $folderCount carpetas, $fileCount archivos en root" -Level "OK"
        }
        else {
            Write-Status "  Sin contenido TFVC." -Level "INFO"
        }
    }
    else {
        # 404 = no TFVC, otros codigos = error real
        if ((Get-ApiErrorStatusCode $tfvcItems) -eq 404) {
            Write-Status "  Sin contenido TFVC (404)." -Level "INFO"
        }
        else {
            Write-Status "  Error consultando TFVC: $(Get-ApiErrorStatusCode $tfvcItems) - $(Get-ApiErrorMessage $tfvcItems)" -Level "WARN"
        }
    }

    # Si no tiene TFVC, registrar y continuar
    if (-not $hasTfvc) {
        $auditResults += [PSCustomObject]@{
            Project            = $projectName
            ProjectId          = $projectId
            HasTfvc            = $false
            RootFolders        = 0
            RootFiles          = 0
            BranchCount        = 0
            LastChangesetId    = "N/A"
            LastChangesetDate  = $null
            LastChangesetAuthor = "N/A"
            IsActive           = $false
            TfvcPipelineCount  = 0
            Status             = "NO_TFVC"
            MigrationAction    = "SKIP"
        }
        continue
    }

    # ---- 2. Obtener branches TFVC ----
    Write-Status "  Obteniendo branches TFVC..."
    $branchUrl = "$AdoBaseUrl/$projectName/_apis/tfvc/branches?includeChildren=true&includeDeleted=false&api-version=$ApiVersion"
    $branchResponse = Invoke-AdoApi -Url $branchUrl -Pat $PatToken

    $branchCount = 0
    if (-not (Test-IsApiError $branchResponse)) {
        $branches = @($branchResponse.value)
        $branchCount = $branches.Count

        foreach ($branch in $branches) {
            $allBranches += [PSCustomObject]@{
                Project     = $projectName
                BranchPath  = $branch.path
                Owner       = $branch.owner.displayName
                CreatedDate = $branch.createdDate
                HasChildren = (@($branch.children).Count -gt 0)
            }

            # Registrar hijos tambien
            if ($branch.children) {
                foreach ($child in $branch.children) {
                    $branchCount++
                    $allBranches += [PSCustomObject]@{
                        Project     = $projectName
                        BranchPath  = $child.path
                        Owner       = $child.owner.displayName
                        CreatedDate = $child.createdDate
                        HasChildren = $false
                    }
                }
            }
        }

        if ($branchCount -gt 0) {
            Write-Status "  $branchCount branch(es) encontrada(s)." -Level "OK"
        }
        else {
            Write-Status "  Sin branches formales (puede ser flat TFVC)." -Level "WARN"
        }
    }
    else {
        Write-Status "  Error obteniendo branches: $(Get-ApiErrorMessage $branchResponse)" -Level "WARN"
    }

    # ---- 3. Ultimo changeset ----
    Write-Status "  Obteniendo ultimo changeset..."
    $csUrl = "$AdoBaseUrl/_apis/tfvc/changesets?searchCriteria.itemPath=`$/$projectName&`$top=1&`$orderby=id desc&api-version=$ApiVersion"
    $csResponse = Invoke-AdoApi -Url $csUrl -Pat $PatToken

    $lastCsId = "N/A"
    $lastCsDate = $null
    $lastCsAuthor = "N/A"
    $isActive = $false

    if (-not (Test-IsApiError $csResponse)) {
        $changesets = @($csResponse.value)
        if ($changesets.Count -gt 0) {
            $lastCs = $changesets[0]
            $lastCsId = $lastCs.changesetId
            $lastCsDate = $lastCs.createdDate
            $lastCsAuthor = $lastCs.author.displayName

            try {
                $parsedDate = [datetime]::Parse($lastCsDate)
                $isActive = ($parsedDate -ge $cutoffDate)
            }
            catch {
                $isActive = $false
            }

            if ($isActive) {
                Write-Status "  Ultimo changeset: #$lastCsId ($lastCsDate) por $lastCsAuthor" -Level "OK"
            }
            else {
                Write-Status "  INACTIVO - Ultimo changeset: #$lastCsId ($lastCsDate)" -Level "WARN"
            }
        }
        else {
            Write-Status "  Sin changesets (repo TFVC vacio)." -Level "WARN"
        }
    }
    else {
        Write-Status "  Error obteniendo changesets: $(Get-ApiErrorMessage $csResponse)" -Level "WARN"
    }

    # ---- 4. Pipelines que apuntan a TFVC ----
    Write-Status "  Verificando pipelines TFVC..."
    $pipeUrl = "$AdoBaseUrl/$projectName/_apis/build/definitions?api-version=$ApiVersion"
    $pipeResponse = Invoke-AdoApi -Url $pipeUrl -Pat $PatToken

    $tfvcPipeCount = 0
    if (-not (Test-IsApiError $pipeResponse)) {
        $pipelines = @($pipeResponse.value)
        foreach ($pipe in $pipelines) {
            # Obtener detalle de cada pipeline para ver repository.type
            $pipeDetailUrl = "$AdoBaseUrl/$projectName/_apis/build/definitions/$($pipe.id)?api-version=$ApiVersion"
            $pipeDetail = Invoke-AdoApi -Url $pipeDetailUrl -Pat $PatToken

            if (-not (Test-IsApiError $pipeDetail)) {
                $repoType = ""
                if ($pipeDetail.repository) {
                    $repoType = $pipeDetail.repository.type
                }

                if ($repoType -eq "TfvcVersionControl" -or $repoType -eq "Tfvc") {
                    $tfvcPipeCount++
                    $allPipelinesTfvc += [PSCustomObject]@{
                        Project        = $projectName
                        PipelineId     = $pipe.id
                        PipelineName   = $pipe.name
                        RepositoryType = $repoType
                        RepositoryName = $pipeDetail.repository.name
                        QueueStatus    = $pipe.queueStatus
                    }
                }
            }
        }

        if ($tfvcPipeCount -gt 0) {
            Write-Status "  $tfvcPipeCount pipeline(s) apuntando a TFVC." -Level "WARN"
        }
        else {
            Write-Status "  Ninguna pipeline apunta a TFVC." -Level "INFO"
        }
    }
    else {
        Write-Status "  Error obteniendo pipelines: $(Get-ApiErrorMessage $pipeResponse)" -Level "WARN"
    }

    # ---- Clasificar accion de migracion ----
    $migrationAction = "EVALUATE"
    if (-not $isActive -and $tfvcPipeCount -eq 0) {
        $migrationAction = "ARCHIVE"
    }
    elseif (-not $isActive -and $tfvcPipeCount -gt 0) {
        $migrationAction = "ARCHIVE_WITH_PIPELINES"
    }
    elseif ($isActive -and $branchCount -eq 0) {
        $migrationAction = "TIP_MIGRATION"
    }
    elseif ($isActive -and $branchCount -le 3) {
        $migrationAction = "TIP_MIGRATION"
    }
    elseif ($isActive -and $branchCount -gt 3) {
        $migrationAction = "COMPLEX_MIGRATION"
    }

    $auditResults += [PSCustomObject]@{
        Project             = $projectName
        ProjectId           = $projectId
        HasTfvc             = $true
        RootFolders         = $folderCount
        RootFiles           = $fileCount
        BranchCount         = $branchCount
        LastChangesetId     = $lastCsId
        LastChangesetDate   = $lastCsDate
        LastChangesetAuthor = $lastCsAuthor
        IsActive            = $isActive
        TfvcPipelineCount   = $tfvcPipeCount
        Status              = $(if ($isActive) { "ACTIVE" } else { "INACTIVE" })
        MigrationAction     = $migrationAction
    }

    $actionColor = switch ($migrationAction) {
        "ARCHIVE"                { "DarkGray" }
        "ARCHIVE_WITH_PIPELINES" { "Yellow" }
        "TIP_MIGRATION"          { "Green" }
        "COMPLEX_MIGRATION"      { "Red" }
        default                  { "White" }
    }
    Write-Host "  Accion recomendada: $migrationAction" -ForegroundColor $actionColor
}

# ----------------------------------------------------------------
# Generar reportes
# ----------------------------------------------------------------

Write-Host ""
Write-Status "Generando reportes..."

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$baseFileName = "tfvc_audit_$timestamp"

# Filtrar solo proyectos con TFVC
$tfvcProjects = @($auditResults | Where-Object { $_.HasTfvc -eq $true })
$noTfvcProjects = @($auditResults | Where-Object { $_.HasTfvc -eq $false })

# CSV principal (todos los proyectos)
$csvPath = Join-Path $OutputDir "${baseFileName}_all_projects.csv"
$auditResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Todos los proyectos: $csvPath"

# CSV solo proyectos con TFVC
if ($tfvcProjects.Count -gt 0) {
    $tfvcCsv = Join-Path $OutputDir "${baseFileName}_tfvc_projects.csv"
    $tfvcProjects | Export-Csv -Path $tfvcCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Proyectos con TFVC: $tfvcCsv"
}

# CSV de branches
if ($allBranches.Count -gt 0) {
    $branchesCsv = Join-Path $OutputDir "${baseFileName}_branches.csv"
    $allBranches | Export-Csv -Path $branchesCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Branches TFVC: $branchesCsv"
}

# CSV de pipelines TFVC
if ($allPipelinesTfvc.Count -gt 0) {
    $pipesCsv = Join-Path $OutputDir "${baseFileName}_tfvc_pipelines.csv"
    $allPipelinesTfvc | Export-Csv -Path $pipesCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Pipelines TFVC: $pipesCsv"
}

# JSON consolidado
$jsonPath = Join-Path $OutputDir "${baseFileName}.json"

$activeWithTfvc = @($tfvcProjects | Where-Object { $_.IsActive -eq $true }).Count
$inactiveWithTfvc = @($tfvcProjects | Where-Object { $_.IsActive -eq $false }).Count
$archiveCandidates = @($tfvcProjects | Where-Object { $_.MigrationAction -like "ARCHIVE*" }).Count
$tipMigration = @($tfvcProjects | Where-Object { $_.MigrationAction -eq "TIP_MIGRATION" }).Count
$complexMigration = @($tfvcProjects | Where-Object { $_.MigrationAction -eq "COMPLEX_MIGRATION" }).Count
$totalPipelinesTfvc = @($allPipelinesTfvc).Count

$summary = [PSCustomObject]@{
    AuditDate              = (Get-Date -Format "o")
    Collection             = $AdoBaseUrl
    TotalProjects          = $allProjects.Count
    ProjectsWithTfvc       = $tfvcProjects.Count
    ProjectsWithoutTfvc    = $noTfvcProjects.Count
    ActiveTfvcProjects     = $activeWithTfvc
    InactiveTfvcProjects   = $inactiveWithTfvc
    TotalBranches          = $allBranches.Count
    TotalTfvcPipelines     = $totalPipelinesTfvc
    ArchiveCandidates      = $archiveCandidates
    TipMigrationCandidates = $tipMigration
    ComplexMigrations      = $complexMigration
    Projects               = $auditResults
    Branches               = $allBranches
    TfvcPipelines          = $allPipelinesTfvc
}

$summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Status "JSON consolidado: $jsonPath"

# ----------------------------------------------------------------
# Resumen en consola
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "             RESUMEN INVENTARIO TFVC" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Collection:              $AdoBaseUrl" -ForegroundColor White
Write-Host "  Total proyectos:         $($allProjects.Count)" -ForegroundColor White
Write-Host "  Proyectos con TFVC:      $($tfvcProjects.Count)" -ForegroundColor Yellow
Write-Host "  Proyectos sin TFVC:      $($noTfvcProjects.Count)" -ForegroundColor DarkGray
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  TFVC activos:            $activeWithTfvc" -ForegroundColor Green
Write-Host "  TFVC inactivos:          $inactiveWithTfvc" -ForegroundColor Yellow
Write-Host "  Total branches TFVC:     $($allBranches.Count)" -ForegroundColor White
Write-Host "  Pipelines apuntando TFVC: $totalPipelinesTfvc" -ForegroundColor White
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  ARCHIVE (inactivo, sin pipelines):  $archiveCandidates" -ForegroundColor DarkGray
Write-Host "  TIP_MIGRATION (simple):             $tipMigration" -ForegroundColor Green
Write-Host "  COMPLEX_MIGRATION (>3 branches):    $complexMigration" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Cyan

# Listar proyectos TFVC activos
if ($activeWithTfvc -gt 0) {
    Write-Host ""
    Write-Status "Proyectos TFVC activos:" -Level "OK"
    $tfvcProjects | Where-Object { $_.IsActive -eq $true } | ForEach-Object {
        $actionColor2 = "White"
        if ($_.MigrationAction -eq "COMPLEX_MIGRATION") { $actionColor2 = "Red" }
        if ($_.MigrationAction -eq "TIP_MIGRATION") { $actionColor2 = "Green" }
        Write-Host "  - $($_.Project): $($_.BranchCount) branches, $($_.TfvcPipelineCount) pipelines, ultimo CS #$($_.LastChangesetId) -> $($_.MigrationAction)" -ForegroundColor $actionColor2
    }
}

# Listar migraciones complejas
if ($complexMigration -gt 0) {
    Write-Host ""
    Write-Status "ATENCION: $complexMigration proyecto(s) con >3 branches TFVC requieren analisis individual." -Level "WARN"
    Write-Status "Considerar git-tfs para historial completo o tip migration + archivo de branches." -Level "WARN"
}

Write-Host ""
Write-Status "Inventario TFVC completado. Reportes en: $OutputDir" -Level "OK"
