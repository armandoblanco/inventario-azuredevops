<#
.SYNOPSIS
    Prueba rápida de acceso TFVC en los 5 proyectos problemáticos.

.DESCRIPTION
    Ejecuta Test-TfvcAccess.ps1 para cada proyecto y genera un resumen.

.EXAMPLE
    .\Test-AllFailedProjects.ps1
#>

[CmdletBinding()]
param()

$projectsToTest = @(
    "TPSAFI",
    "TPContabilidadSeguros",
    "TPBCRComercial",
    "TPBCRClientes",
    "TPAdministradorPolizas"
)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Prueba Rápida de Acceso TFVC - Proyectos Problemáticos" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$results = @()

foreach ($project in $projectsToTest) {
    Write-Host ""
    Write-Host ">>>>>>> Probando: $project" -ForegroundColor Magenta
    Write-Host ""
    
    $scriptPath = Join-Path $PSScriptRoot "Test-TfvcAccess.ps1"
    
    try {
        & $scriptPath -ProjectName $project -ErrorAction Continue
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            $results += [PSCustomObject]@{
                Project = $project
                Status = "SUCCESS"
                HasTfvc = $true
            }
        }
        else {
            $results += [PSCustomObject]@{
                Project = $project
                Status = "NO_TFVC"
                HasTfvc = $false
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            Project = $project
            Status = "ERROR"
            HasTfvc = $false
        }
    }
}

# Resumen final
Write-Host ""
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         RESUMEN FINAL" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$results | Format-Table -AutoSize

$withTfvc = @($results | Where-Object { $_.HasTfvc -eq $true })
$withoutTfvc = @($results | Where-Object { $_.HasTfvc -eq $false })

Write-Host "Proyectos con TFVC: $($withTfvc.Count)" -ForegroundColor Green
Write-Host "Proyectos sin TFVC: $($withoutTfvc.Count)" -ForegroundColor Red
Write-Host ""

if ($withTfvc.Count -gt 0) {
    Write-Host "Los siguientes proyectos tienen TFVC y deberían procesarse:" -ForegroundColor Yellow
    $withTfvc | ForEach-Object { Write-Host "  - $($_.Project)" -ForegroundColor White }
}
