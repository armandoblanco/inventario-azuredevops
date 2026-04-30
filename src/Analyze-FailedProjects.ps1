<#
.SYNOPSIS
    Analiza los 4 proyectos TFVC que fallaron anteriormente.

.DESCRIPTION
    Ejecuta Get-TfvcRepoSize.ps1 con acceso directo para los proyectos:
    - TPSAFI
    - TPContabilidadSeguros
    - TPBCRComercial
    - TPBCRClientes
    - TPAdministradorPolizas

.PARAMETER OutputDir
    Directorio de salida. Default: .\tfvc-size-failed

.EXAMPLE
    .\Analyze-FailedProjects.ps1

.EXAMPLE
    .\Analyze-FailedProjects.ps1 -OutputDir ".\results"
#>

[CmdletBinding()]
param(
    [string]$OutputDir = ".\tfvc-size-failed"
)

$ErrorActionPreference = "Stop"

# Lista de proyectos a analizar
$projectsToAnalyze = @(
    "TPSAFI",
    "TPContabilidadSeguros",
    "TPBCRComercial",
    "TPBCRClientes",
    "TPAdministradorPolizas"
)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Analisis de Proyectos TFVC Individuales" -ForegroundColor Cyan
Write-Host "  Con estrategia mejorada de deteccion TFVC" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Crear directorio de salida
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Crear directorio para logs detallados
$logsDir = Join-Path $OutputDir "logs"
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

$successful = 0
$failed = 0
$results = @()

foreach ($project in $projectsToAnalyze) {
    Write-Host ""
    Write-Host "------------------------------- con log individual
        $scriptPath = Join-Path $PSScriptRoot "Get-TfvcRepoSize.ps1"
        $projectLogFile = Join-Path $logsDir "tfvc_analysis_${project}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        
        & $scriptPath -TeamProject $project -OutputDir $OutputDir -LogFile $projectLogFile -ErrorAction Stop
        
        Write-Host "[OK] $project - Analisis completado" -ForegroundColor Green
        Write-Host "     Log: $projectLogFile" -ForegroundColor Gray
        $successful++
        
        $results += [PSCustomObject]@{
            Project = $project
            Status = "SUCCESS"
            Message = "Analisis completado"
            LogFile = $projectLogFile
        }
    }
    catch {
        Write-Host "[ERROR] $project - $($_.Exception.Message)" -ForegroundColor Red
        $failed++
        
        $results += [PSCustomObject]@{
            Project = $project
            Status = "ERROR"
            Message = $_.Exception.Message
            LogFile = $projectLogFil
        
        $results += [PSCustomObject]@{
            Project = $project
            Status = "ERROR"
            Message = $_.Exception.Message
        }
    }
}

# Resumen final
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         RESUMEN DE ANALISIS" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Total proyectos:    $($projectsToAnalyze.Count)" -ForegroundColor White
Write-Host "  Exitosos:           $successful" -ForegroundColor Green
Write-Host "  Fallidos:           $failed" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Guardar resumen
$summaryPath = Join-Path $OutputDir "analysis_summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$results | ConvertTo-Json -Depth 3 | Out-File -FilePath $summaryPath -Encoding UTF8

Write-Host "Resumen guardado en: $summaryPath" -ForegroundColor Cyan
Write-Host ""

# Retornar codigo de salida
if ($failed -gt 0) {
    exit 1
}
exit 0
