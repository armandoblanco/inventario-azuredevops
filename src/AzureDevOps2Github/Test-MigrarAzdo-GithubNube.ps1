<#
.SYNOPSIS
    Migra repos de Azure DevOps Cloud -> GitHub Cloud usando gh ado2gh migrate-repo.
.DESCRIPTION
    Ejecuta la migracion directa de uno o mas repos de un Team Project en ADO Cloud
    hacia una organizacion en GitHub. Lee credenciales desde .env.
.PARAMETER Repos
    Array de nombres de repositorios a migrar. Ej: -Repos "repo1","repo2","repo3"
.PARAMETER RepoFile
    Ruta a un archivo con la lista de repos (uno por linea). Soporta .txt y .csv.
.PARAMETER TeamProject
    Nombre del Team Project en Azure DevOps. Tambien se puede definir como ADO_TEAM_PROJECT en .env.
.PARAMETER EnvFile
    Ruta al archivo .env. Default: ../.env (carpeta src/)
.EXAMPLE
    # Migrar repos especificos de un Team Project:
    .\Test-MigrarAzdo-GithubNube.ps1 -TeamProject "MiProyecto" -Repos "repo1","repo2"

    # Migrar repos desde un archivo:
    .\Test-MigrarAzdo-GithubNube.ps1 -RepoFile ".\repos-a-migrar.txt"

    # Todo desde .env:
    .\Test-MigrarAzdo-GithubNube.ps1
.NOTES
    Requiere: gh cli con extension ado2gh instalada (gh extension install github/gh-ado2gh).
    Env vars: ADO_PAT, GH_PAT, ADO_ORG, GH_ORG, ADO_TEAM_PROJECT, MIGRATION_REPOS.
#>

[CmdletBinding()]
param(
    [string[]]$Repos,

    [string]$RepoFile,

    [string]$TeamProject,

    [string]$EnvFile = (Join-Path (Split-Path $PSScriptRoot -Parent) ".env")
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
$adoOrg        = if ($env:ADO_ORG)          { $env:ADO_ORG }          else { "CFBCR" }
$githubOrg     = if ($env:GH_ORG)           { $env:GH_ORG }           else { "BCR-Devops" }
$adoTeamProject = if ($TeamProject)         { $TeamProject }
                  elseif ($env:ADO_TEAM_PROJECT) { $env:ADO_TEAM_PROJECT }
                  else { $null }
$adoPat        = $env:ADO_PAT
$githubPat     = $env:GH_PAT

# --- Validar tokens ---
if (-not $adoPat) {
    Write-Host "ERROR: Falta ADO_PAT en .env o variable de entorno." -ForegroundColor Red
    exit 1
}
if (-not $githubPat) {
    Write-Host "ERROR: Falta GH_PAT en .env o variable de entorno." -ForegroundColor Red
    exit 1
}
if (-not $adoTeamProject) {
    Write-Host "ERROR: Falta Team Project. Use -TeamProject o defina ADO_TEAM_PROJECT en .env." -ForegroundColor Red
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

Write-Host "`n=== Migracion ADO Cloud -> GitHub ===" -ForegroundColor Cyan
Write-Host "  ADO Org:      $adoOrg" -ForegroundColor Gray
Write-Host "  Team Project: $adoTeamProject" -ForegroundColor Gray
Write-Host "  GitHub Org:   $githubOrg" -ForegroundColor Gray
Write-Host "  Repos:        $($repoList.Count)" -ForegroundColor Gray
Write-Host ""

# ============================================================
# MIGRAR REPOS DIRECTAMENTE
# ============================================================
# Establece tokens como variables de entorno para gh ado2gh
$env:ADO_PAT = $adoPat
$env:GH_PAT = $githubPat

$successCount = 0
$failCount = 0

foreach ($repo in $repoList) {
    $idx = [array]::IndexOf($repoList, $repo) + 1
    Write-Host "[$idx/$($repoList.Count)] Migrando '$repo'..." -ForegroundColor White

    gh ado2gh migrate-repo `
        --ado-org $adoOrg `
        --ado-team-project $adoTeamProject `
        --ado-repo $repo `
        --github-org $githubOrg `
        --github-repo $repo

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK: $repo migrado exitosamente." -ForegroundColor Green
        $successCount++
    } else {
        Write-Host "  ERROR: Fallo la migracion de '$repo' (exit code: $LASTEXITCODE)." -ForegroundColor Red
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
Write-Host ""