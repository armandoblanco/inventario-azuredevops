<#
.SYNOPSIS
    Get-TfvcRepoSize.ps1
    Obtiene el tamaño de repositorios TFVC en Azure DevOps Server OnPrem.

.DESCRIPTION
    Consulta las APIs REST de TFVC para cada proyecto y calcula:
      1. Tamaño total del repositorio TFVC en bytes
      2. Conteo total de archivos y carpetas
      3. Tamaño formateado (KB, MB, GB)
    Genera CSV y JSON con los resultados.

.PARAMETER AdoBaseUrl
    URL base de la collection. Si no se provee, se lee $env:ADO_BASE (desde .env).

.PARAMETER ProjectFilter
    Filtro opcional por nombre de proyecto (wildcard). Default: * (todos)

.PARAMETER TeamProject
    Nombre exacto de un unico Team Project a auditar. Si se provee, tiene
    precedencia sobre -ProjectFilter y solo se audita ese proyecto.

.PARAMETER OutputDir
    Directorio de salida para reportes. Default: .\tfvc-size

.PARAMETER PatToken
    PAT de ADO Server. Si no se provee, se lee $env:ADO_PAT (desde .env).
    Si no hay PAT, usa credenciales default (NTLM/Kerberos).

.PARAMETER EnvFile
    Ruta al archivo .env con la configuracion. Default: ./.env (junto al script).

.PARAMETER ApiVersion
    Version de la API REST. Default: 5.0 (compatible con ADO Server 2019+)

.EXAMPLE
    # Usando .env (ADO_BASE y ADO_PAT)
    .\Get-TfvcRepoSize.ps1

.EXAMPLE
    .\Get-TfvcRepoSize.ps1 -ProjectFilter "TP*"

.EXAMPLE
    # Obtener tamaño de un unico Team Project
    .\Get-TfvcRepoSize.ps1 -TeamProject "MiProyecto"

.EXAMPLE
    .\Get-TfvcRepoSize.ps1 -AdoBaseUrl "https://server/tfs/Collection" -PatToken $env:ADO_PAT

.NOTES
    Requiere: Conectividad a ADO Server, PowerShell 5.1+
    Operacion: Solo lectura. No modifica nada en el servidor.
    ADVERTENCIA: En repositorios grandes, la consulta puede tardar varios minutos.
#>

[CmdletBinding()]
param(
    [string]$AdoBaseUrl,

    [string]$ProjectFilter = "*",

    [string]$TeamProject,

    [string]$OutputDir = ".\tfvc-size",

    [string]$PatToken,

    [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),

    [string]$ApiVersion = "5.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ----------------------------------------------------------------
# CARGA DE .env
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

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
    else {
        return "$Bytes Bytes"
    }
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

function Get-TfvcItemsRecursive {
    param(
        [string]$BaseUrl,
        [string]$ProjectName,
        [string]$Pat,
        [string]$ApiVer
    )

    # Consultar todos los items recursivamente
    $tfvcUrl = "$BaseUrl/$ProjectName/_apis/tfvc/items?scopePath=`$/$ProjectName&recursionLevel=Full&api-version=$ApiVer"
    $response = Invoke-AdoApi -Url $tfvcUrl -Pat $Pat

    return $response
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Tamaño de Repositorios TFVC - Azure DevOps Server OnPrem" -ForegroundColor Cyan
Write-Host "  Collection: $AdoBaseUrl" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Crear directorio de salida
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Obtener todos los proyectos
Write-Status "Obteniendo lista de proyectos..."
$allProjects = @(Get-AllProjects -BaseUrl $AdoBaseUrl -Pat $PatToken -ApiVer $ApiVersion)
Write-Status "Proyectos en la collection: $($allProjects.Count)"

if ($TeamProject) {
    $allProjects = @($allProjects | Where-Object { $_.name -eq $TeamProject })
    Write-Status "Filtrado a Team Project exacto '$TeamProject': $($allProjects.Count)"
    if ($allProjects.Count -eq 0) {
        Write-Status "El Team Project '$TeamProject' no existe en la collection." -Level "ERROR"
        exit 1
    }
}
elseif ($ProjectFilter -ne "*") {
    $allProjects = @($allProjects | Where-Object { $_.name -like $ProjectFilter })
    Write-Status "Proyectos despues de filtro '$ProjectFilter': $($allProjects.Count)"
}

if ($allProjects.Count -eq 0) {
    Write-Status "No se encontraron proyectos." -Level "WARN"
    exit 0
}

# Resultados
$sizeResults = @()
$projectIndex = 0
$totalSizeAllProjects = 0
$totalFilesAllProjects = 0

foreach ($project in $allProjects) {
    $projectIndex++
    $projectName = $project.name
    $projectId = $project.id

    Write-Host ""
    Write-Status "[$projectIndex/$($allProjects.Count)] $projectName" -Level "INFO"

    # Obtener todos los items TFVC recursivamente
    Write-Status "  Consultando items TFVC (recursivo)... esto puede tardar..."
    $tfvcItems = Get-TfvcItemsRecursive -BaseUrl $AdoBaseUrl -ProjectName $projectName -Pat $PatToken -ApiVer $ApiVersion

    $hasTfvc = $false
    $totalSize = 0
    $fileCount = 0
    $folderCount = 0
    $largestFile = $null
    $largestFileSize = 0

    if (-not (Test-IsApiError $tfvcItems)) {
        $items = @($tfvcItems.value)
        if ($items.Count -gt 0) {
            $hasTfvc = $true

            foreach ($item in $items) {
                if ($item.isFolder) {
                    $folderCount++
                }
                else {
                    $fileCount++
                    $fileSize = 0
                    if ($item.PSObject.Properties.Match('size').Count -gt 0 -and $null -ne $item.size) {
                        $fileSize = [long]$item.size
                    }
                    $totalSize += $fileSize

                    # Registrar archivo mas grande
                    if ($fileSize -gt $largestFileSize) {
                        $largestFileSize = $fileSize
                        $largestFile = $item.path
                    }
                }
            }

            $formattedSize = Format-FileSize -Bytes $totalSize
            Write-Status "  TFVC encontrado: $fileCount archivos, $folderCount carpetas" -Level "OK"
            Write-Status "  Tamaño total: $formattedSize ($totalSize bytes)" -Level "OK"

            if ($largestFile) {
                Write-Status "  Archivo mas grande: $largestFile ($(Format-FileSize -Bytes $largestFileSize))" -Level "INFO"
            }

            $totalSizeAllProjects += $totalSize
            $totalFilesAllProjects += $fileCount
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

    $sizeResults += [PSCustomObject]@{
        Project          = $projectName
        ProjectId        = $projectId
        HasTfvc          = $hasTfvc
        TotalSizeBytes   = $totalSize
        TotalSizeFormatted = $(if ($hasTfvc) { Format-FileSize -Bytes $totalSize } else { "N/A" })
        FileCount        = $fileCount
        FolderCount      = $folderCount
        LargestFile      = $(if ($largestFile) { $largestFile } else { "N/A" })
        LargestFileSizeBytes = $largestFileSize
        LargestFileSizeFormatted = $(if ($largestFileSize -gt 0) { Format-FileSize -Bytes $largestFileSize } else { "N/A" })
    }
}

# ----------------------------------------------------------------
# Generar reportes
# ----------------------------------------------------------------

Write-Host ""
Write-Status "Generando reportes..."

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$baseFileName = "tfvc_size_$timestamp"

# Filtrar solo proyectos con TFVC
$tfvcProjects = @($sizeResults | Where-Object { $_.HasTfvc -eq $true })
$noTfvcProjects = @($sizeResults | Where-Object { $_.HasTfvc -eq $false })

# CSV principal (todos los proyectos)
$csvPath = Join-Path $OutputDir "${baseFileName}_all_projects.csv"
$sizeResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Todos los proyectos: $csvPath"

# CSV solo proyectos con TFVC ordenados por tamaño
if ($tfvcProjects.Count -gt 0) {
    $tfvcCsv = Join-Path $OutputDir "${baseFileName}_tfvc_by_size.csv"
    $tfvcProjects | Sort-Object -Property TotalSizeBytes -Descending | Export-Csv -Path $tfvcCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Proyectos con TFVC (ordenados por tamaño): $tfvcCsv"
}

# JSON consolidado
$jsonPath = Join-Path $OutputDir "${baseFileName}.json"

$summary = [PSCustomObject]@{
    AuditDate                = (Get-Date -Format "o")
    Collection               = $AdoBaseUrl
    TotalProjects            = $allProjects.Count
    ProjectsWithTfvc         = $tfvcProjects.Count
    ProjectsWithoutTfvc      = $noTfvcProjects.Count
    TotalSizeBytes           = $totalSizeAllProjects
    TotalSizeFormatted       = (Format-FileSize -Bytes $totalSizeAllProjects)
    TotalFiles               = $totalFilesAllProjects
    AverageSizePerProject    = $(if ($tfvcProjects.Count -gt 0) { Format-FileSize -Bytes ([long]($totalSizeAllProjects / $tfvcProjects.Count)) } else { "N/A" })
    LargestProject           = $(if ($tfvcProjects.Count -gt 0) { ($tfvcProjects | Sort-Object -Property TotalSizeBytes -Descending | Select-Object -First 1).Project } else { "N/A" })
    LargestProjectSize       = $(if ($tfvcProjects.Count -gt 0) { ($tfvcProjects | Sort-Object -Property TotalSizeBytes -Descending | Select-Object -First 1).TotalSizeFormatted } else { "N/A" })
    Projects                 = $sizeResults
}

$summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Status "JSON consolidado: $jsonPath"

# ----------------------------------------------------------------
# Resumen en consola
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         RESUMEN TAMAÑO REPOSITORIOS TFVC" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Collection:              $AdoBaseUrl" -ForegroundColor White
Write-Host "  Total proyectos:         $($allProjects.Count)" -ForegroundColor White
Write-Host "  Proyectos con TFVC:      $($tfvcProjects.Count)" -ForegroundColor Yellow
Write-Host "  Proyectos sin TFVC:      $($noTfvcProjects.Count)" -ForegroundColor DarkGray
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  TAMAÑO TOTAL TFVC:       $(Format-FileSize -Bytes $totalSizeAllProjects)" -ForegroundColor Green
Write-Host "  Total archivos:          $totalFilesAllProjects" -ForegroundColor White
if ($tfvcProjects.Count -gt 0) {
    $avgSize = [long]($totalSizeAllProjects / $tfvcProjects.Count)
    Write-Host "  Promedio por proyecto:   $(Format-FileSize -Bytes $avgSize)" -ForegroundColor White
}
Write-Host "================================================================" -ForegroundColor Cyan

# Top 10 proyectos por tamaño
if ($tfvcProjects.Count -gt 0) {
    Write-Host ""
    Write-Status "Top 10 proyectos TFVC por tamaño:" -Level "OK"
    $top10 = $tfvcProjects | Sort-Object -Property TotalSizeBytes -Descending | Select-Object -First 10
    $rank = 0
    foreach ($proj in $top10) {
        $rank++
        $sizeColor = "White"
        if ($proj.TotalSizeBytes -ge 1GB) { $sizeColor = "Red" }
        elseif ($proj.TotalSizeBytes -ge 100MB) { $sizeColor = "Yellow" }
        elseif ($proj.TotalSizeBytes -ge 10MB) { $sizeColor = "Green" }
        Write-Host "  $rank. $($proj.Project): $($proj.TotalSizeFormatted) ($($proj.FileCount) archivos)" -ForegroundColor $sizeColor
    }
}

# Advertencia para proyectos grandes
$largeProjects = @($tfvcProjects | Where-Object { $_.TotalSizeBytes -ge 1GB })
if ($largeProjects.Count -gt 0) {
    Write-Host ""
    Write-Status "ATENCION: $($largeProjects.Count) proyecto(s) con mas de 1 GB requieren atencion especial para migracion." -Level "WARN"
    Write-Status "Considerar LFS o limpieza de binarios grandes antes de migrar a Git." -Level "WARN"
}

Write-Host ""
Write-Status "Analisis de tamaño TFVC completado. Reportes en: $OutputDir" -Level "OK"
