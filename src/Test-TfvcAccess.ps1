<#
.SYNOPSIS
    Script de diagnóstico para verificar acceso a repositorios TFVC.

.DESCRIPTION
    Verifica si puede acceder a TFVC en proyectos específicos probando
    múltiples estrategias de consulta a la API.

.PARAMETER AdoBaseUrl
    URL base de la collection. Ejemplo: http://tfs/Collection

.PARAMETER ProjectName
    Nombre del proyecto a diagnosticar.

.PARAMETER PatToken
    PAT de ADO Server. Si no se provee, usa $env:ADO_PAT

.PARAMETER EnvFile
    Ruta al archivo .env. Default: ../.env

.PARAMETER ApiVersion
    Versión de la API REST. Default: 7.0

.EXAMPLE
    .\Test-TfvcAccess.ps1 -ProjectName "TPSAFI"

.EXAMPLE
    .\Test-TfvcAccess.ps1 -AdoBaseUrl "http://tfs/Collection" -ProjectName "TPBCRComercial"
#>

[CmdletBinding()]
param(
    [string]$AdoBaseUrl = $env:ADO_BASE,
    
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    
    [string]$PatToken = $env:ADO_PAT,
    
    [string]$EnvFile = "../.env",
    
    [string]$ApiVersion = "7.0"
)

$ErrorActionPreference = "Continue"

# ----------------------------------------------------------------
# Cargar .env
# ----------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    if (Test-Path $Path) {
        Get-Content $Path | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+?)\s*=\s*(.+?)\s*$') {
                $name = $matches[1]
                $value = $matches[2]
                $value = $value -replace '^["'']|["'']$', ''
                [System.Environment]::SetEnvironmentVariable($name, $value, [System.EnvironmentVariableTarget]::Process)
            }
        }
    }
}

Import-DotEnv -Path $EnvFile

if (-not $AdoBaseUrl) { $AdoBaseUrl = $env:ADO_BASE }
if (-not $PatToken)   { $PatToken   = $env:ADO_PAT }

if (-not $AdoBaseUrl) {
    Write-Error "ADO_BASE no configurado. Usa -AdoBaseUrl o .env"
    exit 1
}
if (-not $PatToken) {
    Write-Error "ADO_PAT no configurado. Usa -PatToken o .env"
    exit 1
}

# ----------------------------------------------------------------
# Funciones
# ----------------------------------------------------------------
function Invoke-AdoApi {
    param([string]$Url, [string]$Pat)

    $headers = @{
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    }

    try {
        $response = Invoke-RestMethod -Uri $Url -Method Get -Headers $headers -ContentType "application/json"
        return $response
    }
    catch {
        return [PSCustomObject]@{
            _error      = $true
            _statusCode = [int]$_.Exception.Response.StatusCode.value__
            _message    = $_.Exception.Message
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

# ----------------------------------------------------------------
# Diagnóstico
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Diagnóstico de Acceso TFVC" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Collection: $AdoBaseUrl" -ForegroundColor White
Write-Host "  Proyecto:   $ProjectName" -ForegroundColor White
Write-Host "  API Ver:    $ApiVersion" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$attempts = @(
    [PSCustomObject]@{
        Name = "Estrategia 1: scopePath=`$/$ProjectName"
        Url = "$AdoBaseUrl/$ProjectName/_apis/tfvc/items?scopePath=`$/$ProjectName&recursionLevel=Full&api-version=$ApiVersion"
    },
    [PSCustomObject]@{
        Name = "Estrategia 2: Sin scopePath"
        Url = "$AdoBaseUrl/$ProjectName/_apis/tfvc/items?recursionLevel=Full&api-version=$ApiVersion"
    },
    [PSCustomObject]@{
        Name = "Estrategia 3: scopePath=`$/"
        Url = "$AdoBaseUrl/$ProjectName/_apis/tfvc/items?scopePath=`$/&recursionLevel=Full&api-version=$ApiVersion"
    },
    [PSCustomObject]@{
        Name = "Estrategia 4: Solo metadata (recursionLevel=None)"
        Url = "$AdoBaseUrl/$ProjectName/_apis/tfvc/items?scopePath=`$/$ProjectName&recursionLevel=None&api-version=$ApiVersion"
    },
    [PSCustomObject]@{
        Name = "Estrategia 5: Verificar proyecto existe"
        Url = "$AdoBaseUrl/_apis/projects/$($ProjectName)?api-version=$ApiVersion"
    }
)

$successCount = 0

foreach ($attempt in $attempts) {
    Write-Host "----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host $attempt.Name -ForegroundColor Yellow
    Write-Host "URL: $($attempt.Url)" -ForegroundColor Gray
    Write-Host ""
    
    $response = Invoke-AdoApi -Url $attempt.Url -Pat $PatToken
    
    if (Test-IsApiError $response) {
        Write-Host "[ERROR] $($response._statusCode) - $($response._message)" -ForegroundColor Red
    }
    else {
        Write-Host "[OK] Respuesta exitosa" -ForegroundColor Green
        $successCount++
        
        # Mostrar detalles de la respuesta
        if ($response.PSObject.Properties.Match('value').Count -gt 0) {
            $items = @($response.value)
            Write-Host "Items encontrados: $($items.Count)" -ForegroundColor Cyan
            
            if ($items.Count -gt 0) {
                $folders = @($items | Where-Object { $_.isFolder -eq $true })
                $files = @($items | Where-Object { $_.isFolder -ne $true })
                Write-Host "  Carpetas: $($folders.Count)" -ForegroundColor White
                Write-Host "  Archivos: $($files.Count)" -ForegroundColor White
                
                if ($folders.Count -gt 0 -and $folders.Count -le 10) {
                    Write-Host "  Carpetas principales:" -ForegroundColor White
                    $folders | Select-Object -First 10 | ForEach-Object {
                        Write-Host "    - $($_.path)" -ForegroundColor Gray
                    }
                }
            }
        }
        elseif ($response.PSObject.Properties.Match('name').Count -gt 0) {
            Write-Host "Proyecto: $($response.name)" -ForegroundColor Cyan
            Write-Host "ID: $($response.id)" -ForegroundColor Cyan
        }
    }
    
    Write-Host ""
}

# ----------------------------------------------------------------
# Resumen
# ----------------------------------------------------------------

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         RESUMEN" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Estrategias exitosas: $successCount / $($attempts.Count)" -ForegroundColor White

if ($successCount -eq 0) {
    Write-Host "  ESTADO: Sin acceso a TFVC" -ForegroundColor Red
    Write-Host ""
    Write-Host "Posibles causas:" -ForegroundColor Yellow
    Write-Host "  1. El proyecto no tiene repositorio TFVC" -ForegroundColor White
    Write-Host "  2. Permisos insuficientes en el PAT" -ForegroundColor White
    Write-Host "  3. El proyecto usa solo Git" -ForegroundColor White
    exit 1
}
elseif ($successCount -eq $attempts.Count -or $successCount -ge 2) {
    Write-Host "  ESTADO: Acceso correcto a TFVC" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "  ESTADO: Acceso parcial" -ForegroundColor Yellow
    exit 0
}
