<#
.SYNOPSIS
    Genera scripts de migracion de Azure DevOps -> GitHub Cloud usando gh ado2gh.
.DESCRIPTION
    Lee credenciales y configuracion desde .env (patron estandar del repo).
    Acepta una lista de repos por parametro, archivo CSV/TXT, o por defecto desde .env.
.PARAMETER Repos
    Array de nombres de repositorios a migrar. Ej: -Repos "repo1","repo2","repo3"
.PARAMETER RepoFile
    Ruta a un archivo con la lista de repos (uno por linea). Soporta .txt y .csv.
.PARAMETER EnvFile
    Ruta al archivo .env. Default: ../.env (carpeta src/)
.PARAMETER OutputFolder
    Nombre de la carpeta de salida para scripts generados. Default: scripts-migracion
.EXAMPLE
    # Migrar repos especificos:
    .\Test-MigrarAzdo-GithubNube.ps1 -Repos "catalogUpdate_AzFLib","otro-repo"

    # Migrar repos desde un archivo:
    .\Test-MigrarAzdo-GithubNube.ps1 -RepoFile ".\repos-a-migrar.txt"

    # Usar .env personalizado:
    .\Test-MigrarAzdo-GithubNube.ps1 -Repos "mi-repo" -EnvFile "C:\config\mi.env"
.NOTES
    Requiere: gh cli con extension ado2gh instalada.
    Las credenciales se leen de .env (ADO_PAT, GH_PAT, ADO_ORG, GH_ORG).
#>

[CmdletBinding()]
param(
    [string[]]$Repos,

    [string]$RepoFile,

    [string]$EnvFile = (Join-Path (Split-Path $PSScriptRoot -Parent) ".env"),

    [string]$OutputFolder = "scripts-migracion"
)

# ============================================================
# CARGA DE .env
# ============================================================
function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "WARN: No se encontro archivo .env en '$Path'. Se usaran variables de entorno actuales." -ForegroundColor DarkYellow
        return
    }
    Write-Host "INFO: Cargando configuracion desde $Path" -ForegroundColor DarkCyan
    Get-Content -Path $Path | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line.StartsWith("#")) { return }
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

# ============================================================
# CONFIGURACION (desde .env o variables de entorno)
# ============================================================
$adoOrg    = if ($env:ADO_ORG)  { $env:ADO_ORG }  else { "CFBCR" }
$githubOrg = if ($env:GH_ORG)  { $env:GH_ORG }   else { "BCR-Devops" }
$adoPat    = $env:ADO_PAT
$githubPat = $env:GH_PAT

# --- Validar tokens ---
if (-not $adoPat) {
    Write-Host "ERROR: Falta ADO_PAT en .env o variable de entorno." -ForegroundColor Red
    exit 1
}
if (-not $githubPat) {
    Write-Host "ERROR: Falta GH_PAT en .env o variable de entorno." -ForegroundColor Red
    exit 1
}

# ============================================================
# RESOLVER LISTA DE REPOS
# ============================================================
$repoList = @()

if ($Repos) {
    $repoList = $Repos
} elseif ($RepoFile) {
    if (-not (Test-Path $RepoFile)) {
        Write-Host "ERROR: No se encontro el archivo de repos '$RepoFile'." -ForegroundColor Red
        exit 1
    }
    $repoList = Get-Content -Path $RepoFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") }
} else {
    # Fallback: variable MIGRATION_REPOS en .env (separados por coma)
    if ($env:MIGRATION_REPOS) {
        $repoList = $env:MIGRATION_REPOS -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
}

if ($repoList.Count -eq 0) {
    Write-Host "ERROR: No se especificaron repos. Use -Repos, -RepoFile, o defina MIGRATION_REPOS en .env." -ForegroundColor Red
    Write-Host "  Ejemplos:" -ForegroundColor Yellow
    Write-Host "    .\Test-MigrarAzdo-GithubNube.ps1 -Repos 'repo1','repo2'" -ForegroundColor Yellow
    Write-Host "    .\Test-MigrarAzdo-GithubNube.ps1 -RepoFile '.\repos.txt'" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n=== Migracion ADO -> GitHub ===" -ForegroundColor Cyan
Write-Host "  ADO Org:    $adoOrg" -ForegroundColor Gray
Write-Host "  GitHub Org: $githubOrg" -ForegroundColor Gray
Write-Host "  Repos:      $($repoList.Count)" -ForegroundColor Gray
Write-Host ""

# ============================================================
# GENERAR SCRIPTS DE MIGRACION
# ============================================================
$outputPath = Join-Path -Path $PSScriptRoot -ChildPath $OutputFolder
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$successCount = 0
$failCount = 0

foreach ($repo in $repoList) {
    $outputFile = Join-Path -Path $outputPath -ChildPath "$repo-migracion.ps1"
    Write-Host "[$($repoList.IndexOf($repo) + 1)/$($repoList.Count)] Generando script para '$repo'..." -ForegroundColor White

    # Establece tokens como variables de entorno para gh ado2gh
    $env:ADO_PAT = $adoPat
    $env:GITHUB_TOKEN = $githubPat

    gh ado2gh generate-script `
        --ado-org $adoOrg `
        --github-org $githubOrg `
        --output $outputFile

    if (Test-Path $outputFile) {
        # Inyecta tokens al inicio del script generado (sin hardcodear, referencia a env vars)
        $patBlock = @"
# Tokens cargados desde variables de entorno - no hardcodear
`$env:ADO_PERSONAL_ACCESS_TOKEN = `$env:ADO_PAT
`$env:GITHUB_TOKEN = `$env:GH_PAT
"@
        $content = Get-Content $outputFile -Raw

        # Reemplaza Read-Host del repo por el nombre concreto
        $content = $content -replace '(\$ado_repo\s*=\s*)Read-Host[^\r\n]*', "`$ado_repo = '$repo'"

        Set-Content $outputFile -Value ($patBlock + "`n" + $content) -Encoding UTF8
        Write-Host "  OK: $outputFile" -ForegroundColor Green
        $successCount++
    } else {
        Write-Host "  ERROR: No se genero el script para '$repo'." -ForegroundColor Red
        $failCount++
    }
}

# ============================================================
# RESUMEN
# ============================================================
Write-Host "`n=== Resumen ===" -ForegroundColor Cyan
Write-Host "  Exitosos: $successCount" -ForegroundColor Green
if ($failCount -gt 0) {
    Write-Host "  Fallidos: $failCount" -ForegroundColor Red
}
Write-Host "  Carpeta:  $outputPath" -ForegroundColor Gray
Write-Host ""