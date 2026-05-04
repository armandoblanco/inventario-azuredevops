<#
.SYNOPSIS
    Get-TfvcRepoSizeByFolder.ps1
    Obtiene el tamaño de repositorios TFVC grandes consultando por subcarpetas.

.DESCRIPTION
    Variante de Get-TfvcRepoSize.ps1 diseñada para proyectos TFVC muy grandes
    que causan errores de memoria (Insufficient memory / Stream was too long)
    cuando se consultan con recursionLevel=Full sobre todo el arbol.

    Estrategia:
      1. Consulta carpetas de primer nivel con recursionLevel=OneLevel
      2. Itera cada subcarpeta con recursionLevel=Full
      3. Si una subcarpeta tambien falla, la subdivide recursivamente
      4. Suma los resultados parciales

    Genera CSV y JSON con los mismos formatos que Get-TfvcRepoSize.ps1.

.PARAMETER AdoBaseUrl
    URL base de la collection. Si no se provee, se lee $env:ADO_BASE (desde .env).

.PARAMETER TeamProject
    Nombre exacto del Team Project a auditar (requerido).

.PARAMETER OutputDir
    Directorio de salida para reportes. Default: .\tfvc-size-byfolder

.PARAMETER PatToken
    PAT de ADO Server. Si no se provee, se lee $env:ADO_PAT (desde .env).
    Si no hay PAT, usa credenciales default (NTLM/Kerberos).

.PARAMETER EnvFile
    Ruta al archivo .env con la configuracion. Default: ./.env (junto al script).

.PARAMETER ApiVersion
    Version de la API REST. Default: 5.0

.PARAMETER LargeFileSizeMB
    Umbral en MB para considerar un archivo como "grande". Default: 5 MB

.PARAMETER DetectNonCodeFiles
    Si se activa, detecta archivos no-codigo. Default: $true

.PARAMETER NonCodeExtensions
    Lista adicional de extensiones a considerar como "no codigo".

.PARAMETER MaxDepth
    Profundidad maxima de subdivision de carpetas cuando una subcarpeta
    tambien falla por memoria. Default: 3

.PARAMETER LogFile
    Ruta del archivo de log. Si no se especifica, se crea automaticamente.

.EXAMPLE
    .\Get-TfvcRepoSizeByFolder.ps1 -TeamProject "TPSAFI"

.EXAMPLE
    .\Get-TfvcRepoSizeByFolder.ps1 -TeamProject "TPBCRComercial" -MaxDepth 4

.EXAMPLE
    # Procesar varios proyectos grandes
    @("TPSAFI","TPContabilidadSeguros","TPBCRComercial","TPBCRClientes","TPAdministradorPolizas") | ForEach-Object {
        .\Get-TfvcRepoSizeByFolder.ps1 -TeamProject $_
    }

.NOTES
    Requiere: Conectividad a ADO Server, PowerShell 5.1+
    Operacion: Solo lectura. No modifica nada en el servidor.
    Diseñado para proyectos que fallan con Get-TfvcRepoSize.ps1 por OOM del servidor.
#>

[CmdletBinding()]
param(
    [string]$AdoBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$TeamProject,

    [string]$OutputDir = ".\tfvc-size-byfolder",

    [string]$PatToken,

    [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),

    [string]$ApiVersion = "5.0",

    [int]$LargeFileSizeMB = 5,

    [bool]$DetectNonCodeFiles = $true,

    [string[]]$NonCodeExtensions,

    [int]$MaxDepth = 3,

    [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ----------------------------------------------------------------
# Extensiones de archivos "no codigo" predeterminadas
# ----------------------------------------------------------------
$DefaultNonCodeExtensions = @(
    ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods", ".odp",
    ".pdf", ".rtf",
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".ico", ".psd", ".ai",
    ".mp4", ".avi", ".mov", ".wmv", ".mkv", ".mp3", ".wav", ".flac",
    ".zip", ".rar", ".7z", ".tar", ".gz", ".bz2",
    ".exe", ".dll", ".msi", ".ocx", ".cab", ".sys",
    ".mdb", ".accdb", ".sqlite", ".bak", ".mdf", ".ldf",
    ".nupkg",
    ".iso", ".img", ".vhd", ".vhdx",
    ".bin", ".dat", ".dump"
)

if ($NonCodeExtensions -and $NonCodeExtensions.Count -gt 0) {
    $AllNonCodeExtensions = ($DefaultNonCodeExtensions + $NonCodeExtensions) | Select-Object -Unique
}
else {
    $AllNonCodeExtensions = $DefaultNonCodeExtensions
}

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

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes Bytes" }
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
        $errorMessage = "Unknown error"
        try {
            if ($null -ne $_.Exception) {
                $errorMessage = $_.Exception.Message
                try {
                    if ($null -ne $_.Exception.Response) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    }
                }
                catch { }
            }
        }
        catch {
            $errorMessage = "Error desconocido al procesar excepcion"
        }
        return [PSCustomObject]@{
            _error      = $true
            _statusCode = $statusCode
            _message    = $errorMessage
            _url        = $Url
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
    if ($Response.PSObject.Properties.Match('_message').Count -gt 0) { return $Response._message }
    return "Unknown error"
}

function Get-ApiErrorStatusCode {
    param($Response)
    if ($null -eq $Response) { return "Unknown" }
    if ($Response.PSObject.Properties.Match('_statusCode').Count -gt 0) { return $Response._statusCode }
    return "Unknown"
}

function Get-FileExtension {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return "" }
    $lastDot = $Path.LastIndexOf(".")
    if ($lastDot -ge 0) { return $Path.Substring($lastDot).ToLower() }
    return ""
}

function Test-IsNonCodeFile {
    param([string]$Path, [string[]]$Extensions)
    $ext = Get-FileExtension -Path $Path
    return ($Extensions -contains $ext)
}

function Get-SafeFolderName {
    param([string]$Name)
    $safeName = $Name -replace '[<>:"/\|?*]', '_'
    $safeName = $safeName -replace '\s+', '_'
    return $safeName
}

# ----------------------------------------------------------------
# Funciones de consulta por subcarpetas
# ----------------------------------------------------------------

function Get-TfvcTopLevelFolders {
    <#
    .SYNOPSIS
        Obtiene las carpetas de primer nivel de un proyecto TFVC usando recursionLevel=OneLevel.
    #>
    param(
        [string]$BaseUrl,
        [string]$ProjectName,
        [string]$Pat,
        [string]$ApiVer
    )

    $scopePath = "`$/$ProjectName"
    $url = "$BaseUrl/$ProjectName/_apis/tfvc/items?scopePath=$scopePath&recursionLevel=OneLevel&api-version=$ApiVer"
    Write-LogOnly "  GET OneLevel: $scopePath"
    $response = Invoke-AdoApi -Url $url -Pat $Pat
    return $response
}

function Get-TfvcSubfolders {
    <#
    .SYNOPSIS
        Obtiene subcarpetas de un path TFVC usando recursionLevel=OneLevel.
    #>
    param(
        [string]$BaseUrl,
        [string]$ProjectName,
        [string]$ScopePath,
        [string]$Pat,
        [string]$ApiVer
    )

    $url = "$BaseUrl/$ProjectName/_apis/tfvc/items?scopePath=$ScopePath&recursionLevel=OneLevel&api-version=$ApiVer"
    Write-LogOnly "    GET OneLevel: $ScopePath"
    $response = Invoke-AdoApi -Url $url -Pat $Pat
    return $response
}

function Get-TfvcItemsForFolder {
    <#
    .SYNOPSIS
        Obtiene todos los items de una carpeta TFVC con recursionLevel=Full.
        Si falla por memoria, subdivide en subcarpetas (hasta MaxDepth).
    #>
    param(
        [string]$BaseUrl,
        [string]$ProjectName,
        [string]$FolderPath,
        [string]$Pat,
        [string]$ApiVer,
        [int]$CurrentDepth = 0,
        [int]$MaxSubdivisionDepth = 3
    )

    $indent = "  " + ("  " * $CurrentDepth)
    Write-LogOnly "${indent}GET Full: $FolderPath (depth=$CurrentDepth)"
    Write-Status "${indent}Consultando: $FolderPath ..." -Level "INFO"

    $url = "$BaseUrl/$ProjectName/_apis/tfvc/items?scopePath=$FolderPath&recursionLevel=Full&api-version=$ApiVer"
    $response = Invoke-AdoApi -Url $url -Pat $Pat

    if (-not (Test-IsApiError $response)) {
        $items = @($response.value)
        Write-LogOnly "${indent}OK: $($items.Count) items en $FolderPath"
        Write-Status "${indent}OK: $($items.Count) items" -Level "OK"
        return $items
    }

    # Si falla, verificar si podemos subdividir
    $errorMsg = Get-ApiErrorMessage $response
    $statusCode = Get-ApiErrorStatusCode $response

    # 404 = carpeta no existe o sin contenido TFVC
    if ($statusCode -eq 404) {
        Write-LogOnly "${indent}404 en $FolderPath - sin contenido"
        Write-Status "${indent}Sin contenido TFVC en $FolderPath" -Level "INFO"
        return @()
    }

    Write-Status "${indent}Error en $FolderPath : $errorMsg" -Level "WARN"
    Write-LogOnly "${indent}Error: $statusCode - $errorMsg"

    # Verificar si podemos subdividir mas
    if ($CurrentDepth -ge $MaxSubdivisionDepth) {
        Write-Status "${indent}LIMITE de profundidad alcanzado ($MaxSubdivisionDepth). No se puede subdividir mas." -Level "ERROR"
        Write-LogOnly "${indent}MAX DEPTH reached for: $FolderPath"
        # Devolver un marcador de error para contabilizar
        return @([PSCustomObject]@{
            _folderError = $true
            _folderPath  = $FolderPath
            _errorMsg    = $errorMsg
        })
    }

    # Subdividir: obtener subcarpetas con OneLevel
    Write-Status "${indent}Subdividiendo $FolderPath en subcarpetas..." -Level "WARN"
    Write-LogOnly "${indent}Subdividing: $FolderPath"

    $subResponse = Get-TfvcSubfolders -BaseUrl $BaseUrl -ProjectName $ProjectName -ScopePath $FolderPath -Pat $Pat -ApiVer $ApiVer

    if (Test-IsApiError $subResponse) {
        Write-Status "${indent}Error al listar subcarpetas de $FolderPath" -Level "ERROR"
        Write-LogOnly "${indent}Cannot list subfolders of $FolderPath : $(Get-ApiErrorMessage $subResponse)"
        return @([PSCustomObject]@{
            _folderError = $true
            _folderPath  = $FolderPath
            _errorMsg    = "Cannot list subfolders: $(Get-ApiErrorMessage $subResponse)"
        })
    }

    $subItems = @($subResponse.value)
    # Separar carpetas de archivos del nivel actual
    $subFolders = @($subItems | Where-Object {
        $isFolder = $false
        if ($_.PSObject.Properties.Match('isFolder').Count -gt 0) { $isFolder = [bool]$_.isFolder }
        $isFolder -and $_.path -ne $FolderPath
    })
    $filesAtLevel = @($subItems | Where-Object {
        $isFolder = $false
        if ($_.PSObject.Properties.Match('isFolder').Count -gt 0) { $isFolder = [bool]$_.isFolder }
        -not $isFolder
    })

    Write-Status "${indent}Encontradas $($subFolders.Count) subcarpetas y $($filesAtLevel.Count) archivos en nivel actual" -Level "INFO"
    Write-LogOnly "${indent}Subfolders: $($subFolders.Count), Files at level: $($filesAtLevel.Count)"

    # Recolectar: archivos del nivel actual + recursion en subcarpetas
    $allItems = @()

    # Agregar archivos sueltos del nivel actual (OneLevel ya los tiene)
    $allItems += $filesAtLevel

    # Agregar la carpeta padre misma (para conteo de carpetas)
    $parentFolder = $subItems | Where-Object { $_.path -eq $FolderPath }
    if ($parentFolder) {
        $allItems += $parentFolder
    }

    # Recursion en cada subcarpeta
    $folderIndex = 0
    foreach ($folder in $subFolders) {
        $folderIndex++
        Write-Status "${indent}Subcarpeta [$folderIndex/$($subFolders.Count)]: $($folder.path)" -Level "INFO"
        $subResult = Get-TfvcItemsForFolder -BaseUrl $BaseUrl -ProjectName $ProjectName `
            -FolderPath $folder.path -Pat $Pat -ApiVer $ApiVer `
            -CurrentDepth ($CurrentDepth + 1) -MaxSubdivisionDepth $MaxSubdivisionDepth
        $allItems += $subResult
    }

    return $allItems
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  TFVC Repo Size (By Folder) - Proyectos Grandes" -ForegroundColor Cyan
Write-Host "  Collection: $AdoBaseUrl" -ForegroundColor Cyan
Write-Host "  Proyecto:   $TeamProject" -ForegroundColor Cyan
Write-Host "  MaxDepth:   $MaxDepth" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Crear directorio de salida
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Configurar log
if (-not $LogFile) {
    $logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogFile = Join-Path $OutputDir "tfvc_byfolder_${TeamProject}_$logTimestamp.log"
}
$script:LogFilePath = $LogFile

# Encabezado del log
"=" * 80 | Out-File -FilePath $script:LogFilePath -Encoding UTF8
"TFVC Repository Size Analysis (By Folder)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"Collection: $AdoBaseUrl" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"Project: $TeamProject" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"MaxDepth: $MaxDepth" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8

Write-Status "Archivo de log: $script:LogFilePath" -Level "OK"

# ----------------------------------------------------------------
# Paso 1: Verificar que el proyecto existe
# ----------------------------------------------------------------
Write-Status "Verificando proyecto '$TeamProject'..."

$projectUrl = "$AdoBaseUrl/_apis/projects/$($TeamProject)?api-version=$ApiVersion"
$projectInfo = Invoke-AdoApi -Url $projectUrl -Pat $PatToken

if (Test-IsApiError $projectInfo) {
    Write-Status "No se pudo acceder al proyecto '$TeamProject': $(Get-ApiErrorMessage $projectInfo)" -Level "ERROR"
    exit 1
}
Write-Status "Proyecto verificado: $($projectInfo.name) (ID: $($projectInfo.id))" -Level "OK"

# ----------------------------------------------------------------
# Paso 2: Obtener carpetas de primer nivel con OneLevel
# ----------------------------------------------------------------
Write-Status "Obteniendo carpetas de primer nivel con OneLevel..."

$topLevelResponse = Get-TfvcTopLevelFolders -BaseUrl $AdoBaseUrl -ProjectName $TeamProject -Pat $PatToken -ApiVer $ApiVersion

if (Test-IsApiError $topLevelResponse) {
    $errMsg = Get-ApiErrorMessage $topLevelResponse
    $errCode = Get-ApiErrorStatusCode $topLevelResponse
    if ($errCode -eq 404) {
        Write-Status "El proyecto '$TeamProject' no tiene contenido TFVC (404)." -Level "WARN"
    }
    else {
        Write-Status "Error obteniendo primer nivel: $errCode - $errMsg" -Level "ERROR"
    }
    exit 1
}

$topLevelItems = @($topLevelResponse.value)
Write-Status "Items en primer nivel: $($topLevelItems.Count)" -Level "OK"

# Separar carpetas de archivos en raiz
$topFolders = @($topLevelItems | Where-Object {
    $isFolder = $false
    if ($_.PSObject.Properties.Match('isFolder').Count -gt 0) { $isFolder = [bool]$_.isFolder }
    $isFolder -and $_.path -ne "`$/$TeamProject"
})
$topFiles = @($topLevelItems | Where-Object {
    $isFolder = $false
    if ($_.PSObject.Properties.Match('isFolder').Count -gt 0) { $isFolder = [bool]$_.isFolder }
    -not $isFolder
})

Write-Status "Carpetas de primer nivel: $($topFolders.Count)" -Level "OK"
if ($topFolders.Count -gt 0) {
    foreach ($tf in $topFolders) {
        Write-Status "  -> $($tf.path)" -Level "INFO"
    }
}
Write-Status "Archivos en raiz: $($topFiles.Count)" -Level "INFO"

# ----------------------------------------------------------------
# Paso 3: Iterar cada subcarpeta con Full (con subdivision si falla)
# ----------------------------------------------------------------
Write-Host ""
Write-Status "Iniciando analisis por subcarpetas..." -Level "OK"

$allItems = @()
$folderErrors = @()

# Agregar archivos sueltos de la raiz
$allItems += $topFiles

# Agregar la carpeta raiz misma
$rootFolder = $topLevelItems | Where-Object { $_.path -eq "`$/$TeamProject" }
if ($rootFolder) {
    $allItems += $rootFolder
}

$folderIndex = 0
$totalFolders = $topFolders.Count

foreach ($folder in $topFolders) {
    $folderIndex++
    $folderPath = $folder.path
    $folderName = $folderPath.Split("/")[-1]

    Write-Host ""
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Status "[$folderIndex/$totalFolders] Procesando: $folderPath" -Level "OK"
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan

    $startTime = Get-Date

    $folderItems = Get-TfvcItemsForFolder -BaseUrl $AdoBaseUrl -ProjectName $TeamProject `
        -FolderPath $folderPath -Pat $PatToken -ApiVer $ApiVersion `
        -CurrentDepth 0 -MaxSubdivisionDepth $MaxDepth

    $elapsed = (Get-Date) - $startTime

    # Separar items validos de errores de carpeta
    $validItems = @($folderItems | Where-Object {
        -not ($_.PSObject.Properties.Match('_folderError').Count -gt 0 -and $_._folderError)
    })
    $errorItems = @($folderItems | Where-Object {
        $_.PSObject.Properties.Match('_folderError').Count -gt 0 -and $_._folderError
    })

    $allItems += $validItems
    if ($errorItems.Count -gt 0) {
        $folderErrors += $errorItems
    }

    # Resumen parcial de esta carpeta
    $folderFiles = @($validItems | Where-Object {
        $isFolder = $false
        if ($_.PSObject.Properties.Match('isFolder').Count -gt 0) { $isFolder = [bool]$_.isFolder }
        -not $isFolder
    })
    $folderSize = ($folderFiles | ForEach-Object {
        $s = 0
        if ($_.PSObject.Properties.Match('size').Count -gt 0 -and $null -ne $_.size) { $s = [long]$_.size }
        $s
    } | Measure-Object -Sum).Sum

    Write-Status "  Completado en $($elapsed.ToString('mm\:ss')): $($folderFiles.Count) archivos, $(Format-FileSize -Bytes $folderSize)" -Level "OK"
    Write-LogOnly "  Folder $folderPath completed: $($validItems.Count) items, $($folderFiles.Count) files, $(Format-FileSize -Bytes $folderSize), elapsed=$($elapsed.ToString('mm\:ss'))"
}

# ----------------------------------------------------------------
# Paso 4: Procesar resultados consolidados
# ----------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Status "Procesando resultados consolidados..." -Level "OK"

$totalSize = [long]0
$fileCount = 0
$folderCount = 0
$largestFile = $null
$largestFileSize = [long]0
$projectLargeFiles = @()
$projectNonCodeFiles = @()
$largeFilesSize = [long]0
$nonCodeFilesSize = [long]0

foreach ($item in $allItems) {
    # Saltar marcadores de error
    if ($item.PSObject.Properties.Match('_folderError').Count -gt 0 -and $item._folderError) { continue }

    $isFolder = $false
    if ($item.PSObject.Properties.Match('isFolder').Count -gt 0) { $isFolder = [bool]$item.isFolder }

    if ($isFolder) {
        $folderCount++
    }
    else {
        $fileCount++
        $fileSize = [long]0
        if ($item.PSObject.Properties.Match('size').Count -gt 0 -and $null -ne $item.size) {
            $fileSize = [long]$item.size
        }
        $totalSize += $fileSize

        if ($fileSize -gt $largestFileSize) {
            $largestFileSize = $fileSize
            $largestFile = $item.path
        }

        if ($fileSize -ge $LargeFileSizeBytes) {
            $projectLargeFiles += [PSCustomObject]@{
                Project       = $TeamProject
                FilePath      = $item.path
                SizeBytes     = $fileSize
                SizeFormatted = Format-FileSize -Bytes $fileSize
                Extension     = Get-FileExtension -Path $item.path
                Reason        = "Large file (>= $LargeFileSizeMB MB)"
            }
            $largeFilesSize += $fileSize
        }

        if ($DetectNonCodeFiles) {
            if (Test-IsNonCodeFile -Path $item.path -Extensions $AllNonCodeExtensions) {
                $projectNonCodeFiles += [PSCustomObject]@{
                    Project       = $TeamProject
                    FilePath      = $item.path
                    SizeBytes     = $fileSize
                    SizeFormatted = Format-FileSize -Bytes $fileSize
                    Extension     = Get-FileExtension -Path $item.path
                    Reason        = "Non-code file type"
                }
                $nonCodeFilesSize += $fileSize
            }
        }
    }
}

# ----------------------------------------------------------------
# Paso 5: Generar reportes
# ----------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$baseFileName = "tfvc_byfolder_${TeamProject}_$timestamp"

# Crear subfolder del proyecto
$projectFolderName = Get-SafeFolderName -Name $TeamProject
$projectFolder = Join-Path $OutputDir $projectFolderName
New-Item -ItemType Directory -Path $projectFolder -Force | Out-Null

# CSV principal
$csvPath = Join-Path $OutputDir "${baseFileName}_summary.csv"
$hasTfvc = ($fileCount -gt 0)
$errorStatus = if ($folderErrors.Count -gt 0) { "PARTIAL" } else { "OK" }
$errorDetail = if ($folderErrors.Count -gt 0) {
    "$($folderErrors.Count) subcarpeta(s) no pudieron ser analizadas"
} else { "" }

$projectResult = [PSCustomObject]@{
    Project              = $TeamProject
    ProjectId            = $projectInfo.id
    HasTfvc              = $hasTfvc
    Status               = $errorStatus
    ErrorDetail          = $errorDetail
    TotalSizeBytes       = $totalSize
    TotalSizeFormatted   = $(if ($hasTfvc) { Format-FileSize -Bytes $totalSize } else { "N/A" })
    FileCount            = $fileCount
    FolderCount          = $folderCount
    LargestFile          = $(if ($largestFile) { $largestFile } else { "N/A" })
    LargestFileSizeBytes = $largestFileSize
    LargestFileSizeFormatted = $(if ($largestFileSize -gt 0) { Format-FileSize -Bytes $largestFileSize } else { "N/A" })
    LargeFilesCount      = $projectLargeFiles.Count
    LargeFilesTotalSize  = Format-FileSize -Bytes $largeFilesSize
    NonCodeFilesCount    = $projectNonCodeFiles.Count
    NonCodeFilesTotalSize = Format-FileSize -Bytes $nonCodeFilesSize
    FolderErrorsCount    = $folderErrors.Count
    AnalysisMethod       = "ByFolder (MaxDepth=$MaxDepth)"
}

$projectResult | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "CSV resumen: $csvPath" -Level "OK"

# CSV archivos grandes
if ($projectLargeFiles.Count -gt 0) {
    $largeFilesCsv = Join-Path $projectFolder "large_files.csv"
    $projectLargeFiles | Sort-Object -Property SizeBytes -Descending | Export-Csv -Path $largeFilesCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Archivos grandes: $largeFilesCsv ($($projectLargeFiles.Count) archivos)" -Level "WARN"
}

# CSV archivos no-codigo
if ($projectNonCodeFiles.Count -gt 0) {
    $nonCodeCsv = Join-Path $projectFolder "non_code_files.csv"
    $projectNonCodeFiles | Sort-Object -Property SizeBytes -Descending | Export-Csv -Path $nonCodeCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Archivos no-codigo: $nonCodeCsv ($($projectNonCodeFiles.Count) archivos)" -Level "WARN"

    # Resumen por extension
    $extSummary = $projectNonCodeFiles | Group-Object -Property Extension | ForEach-Object {
        [PSCustomObject]@{
            Extension          = $_.Name
            FileCount          = $_.Count
            TotalSize          = ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
            TotalSizeFormatted = Format-FileSize -Bytes ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
        }
    } | Sort-Object -Property TotalSize -Descending

    $extSummaryCsv = Join-Path $projectFolder "non_code_by_extension.csv"
    $extSummary | Export-Csv -Path $extSummaryCsv -NoTypeInformation -Encoding UTF8
}

# CSV errores de carpetas (si hubo)
if ($folderErrors.Count -gt 0) {
    $errorsCsv = Join-Path $projectFolder "folder_errors.csv"
    $folderErrors | ForEach-Object {
        [PSCustomObject]@{
            FolderPath = $_._folderPath
            Error      = $_._errorMsg
        }
    } | Export-Csv -Path $errorsCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Carpetas con error: $errorsCsv ($($folderErrors.Count) carpetas)" -Level "ERROR"
}

# JSON consolidado
$jsonPath = Join-Path $OutputDir "${baseFileName}.json"
$summary = [PSCustomObject]@{
    AuditDate                = (Get-Date -Format "o")
    Collection               = $AdoBaseUrl
    Project                  = $TeamProject
    ProjectId                = $projectInfo.id
    AnalysisMethod           = "ByFolder (MaxDepth=$MaxDepth)"
    HasTfvc                  = $hasTfvc
    Status                   = $errorStatus
    TotalSizeBytes           = $totalSize
    TotalSizeFormatted       = (Format-FileSize -Bytes $totalSize)
    FileCount                = $fileCount
    FolderCount              = $folderCount
    LargestFile              = $(if ($largestFile) { $largestFile } else { "N/A" })
    LargestFileSizeFormatted = $(if ($largestFileSize -gt 0) { Format-FileSize -Bytes $largestFileSize } else { "N/A" })
    LargeFileSizeThresholdMB = $LargeFileSizeMB
    LargeFilesCount          = $projectLargeFiles.Count
    LargeFilesTotalSize      = $(if ($projectLargeFiles.Count -gt 0) { Format-FileSize -Bytes $largeFilesSize } else { "0 Bytes" })
    NonCodeFilesCount        = $projectNonCodeFiles.Count
    NonCodeFilesTotalSize    = $(if ($projectNonCodeFiles.Count -gt 0) { Format-FileSize -Bytes $nonCodeFilesSize } else { "0 Bytes" })
    FolderErrorsCount        = $folderErrors.Count
    FolderErrors             = @($folderErrors | ForEach-Object {
        [PSCustomObject]@{ Path = $_._folderPath; Error = $_._errorMsg }
    })
    TopFolderBreakdown       = @($topFolders | ForEach-Object {
        $fPath = $_.path
        $fItems = @($allItems | Where-Object {
            $_.PSObject.Properties.Match('path').Count -gt 0 -and
            $_.path -like "$fPath/*" -and
            -not ($_.PSObject.Properties.Match('_folderError').Count -gt 0 -and $_._folderError)
        })
        $fFiles = @($fItems | Where-Object {
            $isF = $false
            if ($_.PSObject.Properties.Match('isFolder').Count -gt 0) { $isF = [bool]$_.isFolder }
            -not $isF
        })
        $fSize = [long]($fFiles | ForEach-Object {
            $s = 0
            if ($_.PSObject.Properties.Match('size').Count -gt 0 -and $null -ne $_.size) { $s = [long]$_.size }
            $s
        } | Measure-Object -Sum).Sum
        [PSCustomObject]@{
            Folder         = $fPath
            FileCount      = $fFiles.Count
            TotalItems     = $fItems.Count
            SizeBytes      = $fSize
            SizeFormatted  = Format-FileSize -Bytes $fSize
        }
    })
    LargeFiles               = $projectLargeFiles
    NonCodeFiles             = $projectNonCodeFiles
}

$summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Status "JSON consolidado: $jsonPath" -Level "OK"

# ----------------------------------------------------------------
# Resumen en consola
# ----------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     RESUMEN - $TeamProject (By Folder)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Collection:              $AdoBaseUrl" -ForegroundColor White
Write-Host "  Proyecto:                $TeamProject" -ForegroundColor White
Write-Host "  Metodo:                  By Folder (MaxDepth=$MaxDepth)" -ForegroundColor White
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  TAMAÑO TOTAL TFVC:       $(Format-FileSize -Bytes $totalSize)" -ForegroundColor Green
Write-Host "  Total archivos:          $fileCount" -ForegroundColor White
Write-Host "  Total carpetas:          $folderCount" -ForegroundColor White
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Archivos grandes (>=$LargeFileSizeMB MB): $($projectLargeFiles.Count) ($(Format-FileSize -Bytes $largeFilesSize))" -ForegroundColor $(if ($projectLargeFiles.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Archivos no-codigo:      $($projectNonCodeFiles.Count) ($(Format-FileSize -Bytes $nonCodeFilesSize))" -ForegroundColor $(if ($projectNonCodeFiles.Count -gt 0) { "Yellow" } else { "Green" })
if ($folderErrors.Count -gt 0) {
    Write-Host "  Carpetas con ERROR:      $($folderErrors.Count)" -ForegroundColor Red
}
Write-Host "================================================================" -ForegroundColor Cyan

# Desglose por carpeta de primer nivel
if ($topFolders.Count -gt 0) {
    Write-Host ""
    Write-Status "Desglose por carpeta de primer nivel:" -Level "OK"
    foreach ($folder in $topFolders) {
        $fPath = $folder.path
        $fName = $fPath.Split("/")[-1]
        $fItems = @($allItems | Where-Object {
            $_.PSObject.Properties.Match('path').Count -gt 0 -and
            $_.path -like "$fPath/*" -and
            -not ($_.PSObject.Properties.Match('_folderError').Count -gt 0 -and $_._folderError)
        })
        $fFiles = @($fItems | Where-Object {
            $isF = $false
            if ($_.PSObject.Properties.Match('isFolder').Count -gt 0) { $isF = [bool]$_.isFolder }
            -not $isF
        })
        $fSize = [long]($fFiles | ForEach-Object {
            $s = 0
            if ($_.PSObject.Properties.Match('size').Count -gt 0 -and $null -ne $_.size) { $s = [long]$_.size }
            $s
        } | Measure-Object -Sum).Sum

        $sizeColor = "White"
        if ($fSize -ge 1GB) { $sizeColor = "Red" }
        elseif ($fSize -ge 100MB) { $sizeColor = "Yellow" }
        elseif ($fSize -ge 10MB) { $sizeColor = "Green" }

        Write-Host "  $fName : $(Format-FileSize -Bytes $fSize) ($($fFiles.Count) archivos)" -ForegroundColor $sizeColor
    }
}

# Archivo mas grande
if ($largestFile) {
    Write-Host ""
    Write-Status "Archivo mas grande: $largestFile ($(Format-FileSize -Bytes $largestFileSize))" -Level "INFO"
}

# Top 20 archivos grandes
if ($projectLargeFiles.Count -gt 0) {
    Write-Host ""
    Write-Status "Top 20 archivos grandes (>= $LargeFileSizeMB MB):" -Level "WARN"
    $top20 = $projectLargeFiles | Sort-Object -Property SizeBytes -Descending | Select-Object -First 20
    $rank = 0
    foreach ($file in $top20) {
        $rank++
        Write-Host "  $rank. $($file.FilePath) - $($file.SizeFormatted)" -ForegroundColor Yellow
    }
}

# Resumen archivos no-codigo por extension
if ($projectNonCodeFiles.Count -gt 0) {
    Write-Host ""
    Write-Status "Resumen archivos no-codigo por extension:" -Level "WARN"
    $extConsole = $projectNonCodeFiles | Group-Object -Property Extension | ForEach-Object {
        [PSCustomObject]@{
            Extension = $_.Name
            Count     = $_.Count
            TotalSize = ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
        }
    } | Sort-Object -Property TotalSize -Descending | Select-Object -First 15

    foreach ($ext in $extConsole) {
        Write-Host "  $($ext.Extension): $($ext.Count) archivos ($(Format-FileSize -Bytes $ext.TotalSize))" -ForegroundColor Yellow
    }
}

# Carpetas con error
if ($folderErrors.Count -gt 0) {
    Write-Host ""
    Write-Status "CARPETAS QUE NO PUDIERON SER ANALIZADAS:" -Level "ERROR"
    foreach ($err in $folderErrors) {
        Write-Host "  - $($_._folderPath): $($_._errorMsg)" -ForegroundColor Red
    }
    Write-Host ""
    Write-Status "Sugerencia: Incrementar -MaxDepth o analizar estas carpetas manualmente." -Level "WARN"
}

Write-Host ""
Write-Status "Analisis completado. Reportes en: $OutputDir" -Level "OK"

# Cerrar log con resumen
if ($script:LogFilePath) {
    "" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "RESUMEN FINAL" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Project: $TeamProject" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Method: ByFolder (MaxDepth=$MaxDepth)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Has TFVC: $hasTfvc" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Total Size: $(Format-FileSize -Bytes $totalSize)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Total Files: $fileCount" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Total Folders: $folderCount" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Large Files (>= $LargeFileSizeMB MB): $($projectLargeFiles.Count)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Non-Code Files: $($projectNonCodeFiles.Count)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Folder Errors: $($folderErrors.Count)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    if ($folderErrors.Count -gt 0) {
        "" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
        "CARPETAS CON ERROR:" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
        foreach ($err in $folderErrors) {
            "  - $($err._folderPath): $($err._errorMsg)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
        }
    }
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    Write-Status "Log guardado en: $script:LogFilePath" -Level "OK"
}
