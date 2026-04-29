<#
.SYNOPSIS
    Get-TfvcRepoSize.ps1
    Obtiene el tamaño de repositorios TFVC en Azure DevOps Server OnPrem.

.DESCRIPTION
    Consulta las APIs REST de TFVC para cada proyecto y calcula:
      1. Tamaño total del repositorio TFVC en bytes
      2. Conteo total de archivos y carpetas
      3. Tamaño formateado (KB, MB, GB)
      4. Archivos grandes (mayores al umbral configurable)
      5. Archivos no-codigo (binarios, documentos, etc.)
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

.PARAMETER LargeFileSizeMB
    Umbral en MB para considerar un archivo como "grande". Default: 5 MB

.PARAMETER DetectNonCodeFiles
    Si se activa, detecta archivos que no deberian estar en codigo fuente
    (binarios, documentos Office, PDFs, videos, etc.). Default: $true

.PARAMETER NonCodeExtensions
    Lista adicional de extensiones a considerar como "no codigo".
    Se combinan con la lista predeterminada.

.PARAMETER ExcludeProjects
    Lista de nombres de Team Projects a excluir del analisis.
    Soporta wildcards (ej: "Test*", "*Backup").

.PARAMETER LogFile
    Ruta del archivo de log. Si no se especifica, se crea automaticamente
    en OutputDir con timestamp.

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

.EXAMPLE
    # Detectar archivos mayores a 10 MB
    .\Get-TfvcRepoSize.ps1 -LargeFileSizeMB 10

.EXAMPLE
    # Agregar extensiones adicionales a detectar
    .\Get-TfvcRepoSize.ps1 -NonCodeExtensions @(".bak", ".tmp", ".log")

.EXAMPLE
    # Excluir proyectos especificos
    .\Get-TfvcRepoSize.ps1 -ExcludeProjects @("TestProject", "Sandbox*", "*Backup")

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

    [string]$ApiVersion = "5.0",

    [int]$LargeFileSizeMB = 5,

    [bool]$DetectNonCodeFiles = $true,

    [string[]]$NonCodeExtensions,

    [string[]]$ExcludeProjects,

    [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ----------------------------------------------------------------
# Extensiones de archivos "no codigo" predeterminadas
# ----------------------------------------------------------------
$DefaultNonCodeExtensions = @(
    # Documentos Office
    ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods", ".odp",
    # PDFs y documentos
    ".pdf", ".rtf",
    # Imagenes
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".ico", ".psd", ".ai",
    # Videos y audio
    ".mp4", ".avi", ".mov", ".wmv", ".mkv", ".mp3", ".wav", ".flac",
    # Archivos comprimidos
    ".zip", ".rar", ".7z", ".tar", ".gz", ".bz2",
    # Ejecutables y binarios
    ".exe", ".dll", ".msi", ".ocx", ".cab", ".sys",
    # Bases de datos
    ".mdb", ".accdb", ".sqlite", ".bak", ".mdf", ".ldf",
    # Paquetes NuGet/npm (no deberian estar en source control)
    ".nupkg",
    # Archivos de instalacion
    ".iso", ".img", ".vhd", ".vhdx",
    # Otros binarios comunes
    ".bin", ".dat", ".dump"
)

# Combinar extensiones custom con default si se proporcionaron
if ($NonCodeExtensions -and $NonCodeExtensions.Count -gt 0) {
    $AllNonCodeExtensions = ($DefaultNonCodeExtensions + $NonCodeExtensions) | Select-Object -Unique
}
else {
    $AllNonCodeExtensions = $DefaultNonCodeExtensions
}

# Calcular umbral en bytes
$LargeFileSizeBytes = $LargeFileSizeMB * 1MB

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

# Variable global para el archivo de log
$script:LogFilePath = $null

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
    $logLine = "[$timestamp][$Level] $Message"
    Write-Host $logLine -ForegroundColor $color
    
    # Escribir al archivo de log si esta configurado
    if ($script:LogFilePath) {
        $logLine | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
}

function Write-LogOnly {
    param([string]$Message)
    if ($script:LogFilePath) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        "[$timestamp] $Message" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
}

function Test-ProjectExcluded {
    param(
        [string]$ProjectName,
        [string[]]$ExcludePatterns
    )
    if (-not $ExcludePatterns -or $ExcludePatterns.Count -eq 0) {
        return $false
    }
    foreach ($pattern in $ExcludePatterns) {
        if ($ProjectName -like $pattern) {
            return $true
        }
    }
    return $false
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

function Get-FileExtension {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return "" }
    $lastDot = $Path.LastIndexOf(".")
    if ($lastDot -ge 0) {
        return $Path.Substring($lastDot).ToLower()
    }
    return ""
}

function Test-IsNonCodeFile {
    param(
        [string]$Path,
        [string[]]$Extensions
    )
    $ext = Get-FileExtension -Path $Path
    return ($Extensions -contains $ext)
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

# Configurar archivo de log
if (-not $LogFile) {
    $logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogFile = Join-Path $OutputDir "tfvc_size_$logTimestamp.log"
}
$script:LogFilePath = $LogFile

# Escribir encabezado del log
"=" * 80 | Out-File -FilePath $script:LogFilePath -Encoding UTF8
"TFVC Repository Size Analysis Log" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"Collection: $AdoBaseUrl" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
if ($ExcludeProjects -and $ExcludeProjects.Count -gt 0) {
    "Excluded patterns: $($ExcludeProjects -join ', ')" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
}
"=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8

Write-Status "Archivo de log: $script:LogFilePath" -Level "OK"

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

# Aplicar exclusiones
if ($ExcludeProjects -and $ExcludeProjects.Count -gt 0) {
    $beforeExclude = $allProjects.Count
    $excludedList = @()
    $allProjects = @($allProjects | Where-Object { 
        $excluded = Test-ProjectExcluded -ProjectName $_.name -ExcludePatterns $ExcludeProjects
        if ($excluded) { $excludedList += $_.name }
        -not $excluded
    })
    $excludedCount = $beforeExclude - $allProjects.Count
    if ($excludedCount -gt 0) {
        Write-Status "Proyectos excluidos: $excludedCount" -Level "WARN"
        foreach ($excl in $excludedList) {
            Write-LogOnly "  Excluido: $excl"
        }
    }
    Write-Status "Proyectos a procesar despues de exclusiones: $($allProjects.Count)"
}

if ($allProjects.Count -eq 0) {
    Write-Status "No se encontraron proyectos." -Level "WARN"
    exit 0
}

# Resultados
$sizeResults = @()
$allLargeFiles = @()
$allNonCodeFiles = @()
$projectIndex = 0
$totalSizeAllProjects = 0
$totalFilesAllProjects = 0

# Preparar archivos de salida incremental
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$baseFileName = "tfvc_size_$timestamp"

# CSV principal en la raiz (resumen de todos los proyectos)
$csvPath = Join-Path $OutputDir "${baseFileName}_all_projects.csv"

# Crear header del CSV principal
$projectHeaders = "Project,ProjectId,HasTfvc,TotalSizeBytes,TotalSizeFormatted,FileCount,FolderCount,LargestFile,LargestFileSizeBytes,LargestFileSizeFormatted,LargeFilesCount,LargeFilesTotalSize,NonCodeFilesCount,NonCodeFilesTotalSize"
$projectHeaders | Out-File -FilePath $csvPath -Encoding UTF8

Write-Status "CSV principal creado en: $csvPath" -Level "OK"
Write-Status "Se creara un subfolder por cada proyecto con sus archivos de detalle" -Level "INFO"

# Funcion para sanitizar nombre de carpeta
function Get-SafeFolderName {
    param([string]$Name)
    # Reemplazar caracteres no validos para nombres de carpeta
    $safeName = $Name -replace '[<>:"/\|?*]', '_'
    $safeName = $safeName -replace '\s+', '_'
    return $safeName
}

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
    $projectLargeFiles = @()
    $projectNonCodeFiles = @()
    $largeFilesSize = 0
    $nonCodeFilesSize = 0

    if (-not (Test-IsApiError $tfvcItems)) {
        $items = @($tfvcItems.value)
        if ($items.Count -gt 0) {
            $hasTfvc = $true

            foreach ($item in $items) {
                # Verificar si es carpeta (la propiedad puede no existir)
                $isFolder = $false
                if ($item.PSObject.Properties.Match('isFolder').Count -gt 0) {
                    $isFolder = [bool]$item.isFolder
                }
                
                if ($isFolder) {
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

                    # Detectar archivos grandes (>= umbral)
                    if ($fileSize -ge $LargeFileSizeBytes) {
                        $largeFileInfo = [PSCustomObject]@{
                            Project       = $projectName
                            FilePath      = $item.path
                            SizeBytes     = $fileSize
                            SizeFormatted = Format-FileSize -Bytes $fileSize
                            Extension     = Get-FileExtension -Path $item.path
                            Reason        = "Large file (>= $LargeFileSizeMB MB)"
                        }
                        $projectLargeFiles += $largeFileInfo
                        $largeFilesSize += $fileSize
                    }

                    # Detectar archivos no-codigo
                    if ($DetectNonCodeFiles) {
                        $ext = Get-FileExtension -Path $item.path
                        if (Test-IsNonCodeFile -Path $item.path -Extensions $AllNonCodeExtensions) {
                            $nonCodeFileInfo = [PSCustomObject]@{
                                Project       = $projectName
                                FilePath      = $item.path
                                SizeBytes     = $fileSize
                                SizeFormatted = Format-FileSize -Bytes $fileSize
                                Extension     = $ext
                                Reason        = "Non-code file type"
                            }
                            $projectNonCodeFiles += $nonCodeFileInfo
                            $nonCodeFilesSize += $fileSize
                        }
                    }
                }
            }

            $formattedSize = Format-FileSize -Bytes $totalSize
            Write-Status "  TFVC encontrado: $fileCount archivos, $folderCount carpetas" -Level "OK"
            Write-Status "  Tamaño total: $formattedSize ($totalSize bytes)" -Level "OK"

            if ($largestFile) {
                Write-Status "  Archivo mas grande: $largestFile ($(Format-FileSize -Bytes $largestFileSize))" -Level "INFO"
            }

            # Reportar archivos grandes encontrados
            if ($projectLargeFiles.Count -gt 0) {
                Write-Status "  Archivos grandes (>= $LargeFileSizeMB MB): $($projectLargeFiles.Count) archivos ($(Format-FileSize -Bytes $largeFilesSize))" -Level "WARN"
                $allLargeFiles += $projectLargeFiles
            }

            # Reportar archivos no-codigo encontrados
            if ($projectNonCodeFiles.Count -gt 0) {
                Write-Status "  Archivos no-codigo: $($projectNonCodeFiles.Count) archivos ($(Format-FileSize -Bytes $nonCodeFilesSize))" -Level "WARN"
                $allNonCodeFiles += $projectNonCodeFiles
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

    $projectResult = [PSCustomObject]@{
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
        LargeFilesCount  = $projectLargeFiles.Count
        LargeFilesTotalSize = $(Format-FileSize -Bytes $largeFilesSize)
        NonCodeFilesCount = $projectNonCodeFiles.Count
        NonCodeFilesTotalSize = $(Format-FileSize -Bytes $nonCodeFilesSize)
    }
    
    $sizeResults += $projectResult
    
    # Escribir resultado del proyecto de forma incremental al CSV principal (raiz)
    $projectLine = "`"$($projectResult.Project)`",`"$($projectResult.ProjectId)`",$($projectResult.HasTfvc),$($projectResult.TotalSizeBytes),`"$($projectResult.TotalSizeFormatted)`",$($projectResult.FileCount),$($projectResult.FolderCount),`"$($projectResult.LargestFile)`",$($projectResult.LargestFileSizeBytes),`"$($projectResult.LargestFileSizeFormatted)`",$($projectResult.LargeFilesCount),`"$($projectResult.LargeFilesTotalSize)`",$($projectResult.NonCodeFilesCount),`"$($projectResult.NonCodeFilesTotalSize)`""
    $projectLine | Out-File -FilePath $csvPath -Append -Encoding UTF8
    
    # Crear subfolder del proyecto
    $projectFolderName = Get-SafeFolderName -Name $projectName
    $projectFolder = Join-Path $OutputDir $projectFolderName
    New-Item -ItemType Directory -Path $projectFolder -Force | Out-Null
    
    # Guardar resumen del proyecto en su subfolder
    $projectSummaryCsv = Join-Path $projectFolder "summary.csv"
    $projectResult | Export-Csv -Path $projectSummaryCsv -NoTypeInformation -Encoding UTF8
    
    # Guardar archivos grandes del proyecto en su subfolder
    if ($projectLargeFiles.Count -gt 0) {
        $projectLargeFilesCsv = Join-Path $projectFolder "large_files.csv"
        $projectLargeFiles | Sort-Object -Property SizeBytes -Descending | Export-Csv -Path $projectLargeFilesCsv -NoTypeInformation -Encoding UTF8
        Write-Status "  -> $projectFolder/large_files.csv ($($projectLargeFiles.Count) archivos)" -Level "WARN"
    }
    
    # Guardar archivos no-codigo del proyecto en su subfolder
    if ($projectNonCodeFiles.Count -gt 0) {
        $projectNonCodeCsv = Join-Path $projectFolder "non_code_files.csv"
        $projectNonCodeFiles | Sort-Object -Property SizeBytes -Descending | Export-Csv -Path $projectNonCodeCsv -NoTypeInformation -Encoding UTF8
        Write-Status "  -> $projectFolder/non_code_files.csv ($($projectNonCodeFiles.Count) archivos)" -Level "WARN"
    }
    
    Write-Status "  Resultados guardados en: $projectFolder/" -Level "OK"
}

# ----------------------------------------------------------------
# Generar reportes finales consolidados en la raiz
# ----------------------------------------------------------------

Write-Host ""
Write-Status "Generando reportes consolidados en la raiz..."

# Filtrar solo proyectos con TFVC
$tfvcProjects = @($sizeResults | Where-Object { $_.HasTfvc -eq $true })
$noTfvcProjects = @($sizeResults | Where-Object { $_.HasTfvc -eq $false })

Write-Status "CSV principal completado: $csvPath"

# CSV solo proyectos con TFVC ordenados por tamaño
if ($tfvcProjects.Count -gt 0) {
    $tfvcCsv = Join-Path $OutputDir "${baseFileName}_tfvc_by_size.csv"
    $tfvcProjects | Sort-Object -Property TotalSizeBytes -Descending | Export-Csv -Path $tfvcCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Proyectos con TFVC (ordenados por tamaño): $tfvcCsv"
}

# CSV consolidado de archivos grandes (todos los proyectos)
if ($allLargeFiles.Count -gt 0) {
    $largeFilesCsvConsolidated = Join-Path $OutputDir "${baseFileName}_large_files_all.csv"
    $allLargeFiles | Sort-Object -Property SizeBytes -Descending | Export-Csv -Path $largeFilesCsvConsolidated -NoTypeInformation -Encoding UTF8
    Write-Status "Archivos grandes consolidado (>= $LargeFileSizeMB MB): $largeFilesCsvConsolidated" -Level "WARN"
}

# CSV consolidado de archivos no-codigo (todos los proyectos)
if ($allNonCodeFiles.Count -gt 0) {
    $nonCodeCsvConsolidated = Join-Path $OutputDir "${baseFileName}_non_code_files_all.csv"
    $allNonCodeFiles | Sort-Object -Property SizeBytes -Descending | Export-Csv -Path $nonCodeCsvConsolidated -NoTypeInformation -Encoding UTF8
    Write-Status "Archivos no-codigo consolidado: $nonCodeCsvConsolidated" -Level "WARN"

    # Resumen por extension
    $extSummary = $allNonCodeFiles | Group-Object -Property Extension | ForEach-Object {
        [PSCustomObject]@{
            Extension  = $_.Name
            FileCount  = $_.Count
            TotalSize  = ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
            TotalSizeFormatted = Format-FileSize -Bytes ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
        }
    } | Sort-Object -Property TotalSize -Descending
    
    $extSummaryCsv = Join-Path $OutputDir "${baseFileName}_non_code_by_extension.csv"
    $extSummary | Export-Csv -Path $extSummaryCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Resumen por extension: $extSummaryCsv" -Level "WARN"
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
    LargeFileSizeThresholdMB = $LargeFileSizeMB
    TotalLargeFiles          = $allLargeFiles.Count
    TotalLargeFilesSize      = $(if ($allLargeFiles.Count -gt 0) { Format-FileSize -Bytes ($allLargeFiles | Measure-Object -Property SizeBytes -Sum).Sum } else { "0 Bytes" })
    TotalNonCodeFiles        = $allNonCodeFiles.Count
    TotalNonCodeFilesSize    = $(if ($allNonCodeFiles.Count -gt 0) { Format-FileSize -Bytes ($allNonCodeFiles | Measure-Object -Property SizeBytes -Sum).Sum } else { "0 Bytes" })
    Projects                 = $sizeResults
    LargeFiles               = $allLargeFiles
    NonCodeFiles             = $allNonCodeFiles
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
Write-Host "  Archivos grandes (>=$LargeFileSizeMB MB): $($allLargeFiles.Count)" -ForegroundColor $(if ($allLargeFiles.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Archivos no-codigo:     $($allNonCodeFiles.Count)" -ForegroundColor $(if ($allNonCodeFiles.Count -gt 0) { "Yellow" } else { "Green" })
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

# Top 20 archivos grandes
if ($allLargeFiles.Count -gt 0) {
    Write-Host ""
    Write-Status "Top 20 archivos grandes (>= $LargeFileSizeMB MB):" -Level "WARN"
    $top20Large = $allLargeFiles | Sort-Object -Property SizeBytes -Descending | Select-Object -First 20
    $rank = 0
    foreach ($file in $top20Large) {
        $rank++
        Write-Host "  $rank. [$($file.Project)] $($file.FilePath) - $($file.SizeFormatted)" -ForegroundColor Yellow
    }
}

# Resumen de archivos no-codigo por extension
if ($allNonCodeFiles.Count -gt 0) {
    Write-Host ""
    Write-Status "Resumen archivos no-codigo por extension:" -Level "WARN"
    $extSummaryConsole = $allNonCodeFiles | Group-Object -Property Extension | ForEach-Object {
        [PSCustomObject]@{
            Extension = $_.Name
            Count     = $_.Count
            TotalSize = ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
        }
    } | Sort-Object -Property TotalSize -Descending | Select-Object -First 15
    
    foreach ($ext in $extSummaryConsole) {
        $sizeFormatted = Format-FileSize -Bytes $ext.TotalSize
        Write-Host "  $($ext.Extension): $($ext.Count) archivos ($sizeFormatted)" -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Status "RECOMENDACION: Revisar archivos no-codigo antes de migrar a Git." -Level "WARN"
    Write-Status "Considerar: 1) Eliminar si no son necesarios, 2) Mover a storage externo, 3) Usar Git LFS" -Level "WARN"
}

Write-Host ""
Write-Status "Analisis de tamaño TFVC completado. Reportes en: $OutputDir" -Level "OK"

# Cerrar el archivo de log con resumen
if ($script:LogFilePath) {
    "" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "RESUMEN FINAL" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Total proyectos analizados: $($allProjects.Count)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Proyectos con TFVC: $($tfvcProjects.Count)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Proyectos sin TFVC: $($noTfvcProjects.Count)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Tamaño total TFVC: $(Format-FileSize -Bytes $totalSizeAllProjects)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Total archivos: $totalFilesAllProjects" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Archivos grandes (>= $LargeFileSizeMB MB): $($allLargeFiles.Count)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Archivos no-codigo: $($allNonCodeFiles.Count)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    Write-Status "Log guardado en: $script:LogFilePath" -Level "OK"
}
