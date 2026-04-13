<#
.SYNOPSIS
    POC: Migracion ADO Server OnPrem -> GitHub (BCR-Devops)
    3 repos Git (mirror) + 3 repos TFVC (tip migration)
.DESCRIPTION
    Solo lectura en ADO. Crea repos nuevos en GitHub.
    Requiere: git instalado, conectividad a bcrtfs y github.com
.EXAMPLE
    $env:GH_PAT = "ghp_tu_token_github"
    $env:ADO_PAT = "tu_pat_ado"
    .\Migrate-POC.ps1
#>

# ============================================================
# CONFIGURACION
# ============================================================
$ADO_BASE    = "https://bcrtfs/tfs/BCRCollection"
$GH_ORG      = "BCR-Devops"
$GH_PAT      = $env:GH_PAT
$ADO_PAT     = $env:ADO_PAT
$WORKDIR     = "C:\migration-poc"

# --- Validar tokens ---
if (-not $GH_PAT) {
    Write-Host "ERROR: Falta GH_PAT. Ejecute: `$env:GH_PAT = 'ghp_xxx'" -ForegroundColor Red
    exit 1
}
if (-not $ADO_PAT) {
    Write-Host "WARN: No se definio ADO_PAT. Se usara autenticacion Windows (NTLM)." -ForegroundColor Yellow
}

# --- Repos Git (clone mirror directo) ---
$gitRepos = @(
    @{ Project = "TPBCRComercial"; Repo = "bcr_comercial_restapi_prestamos_netcore" },
    @{ Project = "TPBCRComercial"; Repo = "bcr_comercial_pruebas_funcionales_automatizadas" },
    @{ Project = "TPBCRComercial"; Repo = "bcr-comercial-restapicommon-netcore" }
)

# --- Repos TFVC (tip migration via API ZIP) ---
$tfvcRepos = @(
    @{ Project = "TPEmisionEstadosCuenta"; TfvcPath = "$/TPEmisionEstadosCuenta"; GitName = "TPEmisionEstadosCuenta" },
    @{ Project = "GerenciaBanprocesa";     TfvcPath = "$/GerenciaBanprocesa";     GitName = "GerenciaBanprocesa" },
    @{ Project = "TPFinesse";              TfvcPath = "$/TPFinesse";              GitName = "TPFinesse" }
)

# ============================================================
# Funciones
# ============================================================

function New-GitHubRepo {
    param([string]$Org, [string]$RepoName, [string]$Pat)
    $headers = @{
        Authorization = "token $Pat"
        Accept        = "application/vnd.github+json"
    }
    $body = @{ name = $RepoName; private = $true; auto_init = $false } | ConvertTo-Json
    try {
        $null = Invoke-RestMethod -Uri "https://api.github.com/orgs/$Org/repos" `
            -Method Post -Headers $headers -Body $body -ContentType "application/json"
        Write-Host "    Repo creado en GitHub." -ForegroundColor Green
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match '422') {
            Write-Host "    Repo ya existe en GitHub, continuando." -ForegroundColor Yellow
        }
        else {
            Write-Host "    Error creando repo: $msg" -ForegroundColor Red
            return $false
        }
    }
    return $true
}

# ============================================================
# INICIO
# ============================================================

if (Test-Path $WORKDIR) { Remove-Item -Recurse -Force $WORKDIR }
New-Item -ItemType Directory -Path $WORKDIR -Force | Out-Null
Set-Location $WORKDIR

$results = @()
$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  POC Migracion: ADO Server OnPrem -> GitHub" -ForegroundColor Cyan
Write-Host "  Org GitHub : $GH_ORG" -ForegroundColor Cyan
Write-Host "  ADO Base   : $ADO_BASE" -ForegroundColor Cyan
Write-Host "  Git repos  : $($gitRepos.Count)" -ForegroundColor Cyan
Write-Host "  TFVC repos : $($tfvcRepos.Count)" -ForegroundColor Cyan
Write-Host "  Directorio : $WORKDIR" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ============================================================
# PARTE 1: Repos Git
# ============================================================

Write-Host ""
Write-Host "========== PARTE 1: Repos Git (mirror clone + push) ==========" -ForegroundColor Cyan

foreach ($r in $gitRepos) {
    $repo = $r.Repo
    $project = $r.Project
    Write-Host ""
    Write-Host "--- [$repo] ---" -ForegroundColor White

    $mirrorPath = Join-Path $WORKDIR "$repo.git"
    $ghRepoUrl = "https://github.com/$GH_ORG/$repo.git"

    # 1. Clone mirror
    Write-Host "  [1/4] Clone mirror desde ADO..." -ForegroundColor Yellow
    if (Test-Path $mirrorPath) { Remove-Item -Recurse -Force $mirrorPath }

    $cloneUrl = "$ADO_BASE/$project/_git/$repo"
    if ($ADO_PAT) {
        $cloneUrl = $cloneUrl -replace 'https://', "https://user:$ADO_PAT@"
    }

    & git clone --mirror $cloneUrl $mirrorPath 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

    if (-not (Test-Path (Join-Path $mirrorPath "HEAD"))) {
        Write-Host "  FALLO: clone no completado" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status="CLONE_FAILED"; Detail="" }
        continue
    }
    Write-Host "    Clone OK." -ForegroundColor Green

    # 2. Crear repo en GitHub
    Write-Host "  [2/4] Creando repo en GitHub..." -ForegroundColor Yellow
    $created = New-GitHubRepo -Org $GH_ORG -RepoName $repo -Pat $GH_PAT
    if ($created -eq $false) {
        $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status="GH_CREATE_FAILED"; Detail="" }
        continue
    }

    # 3. Push mirror
    Write-Host "  [3/4] Push mirror a GitHub..." -ForegroundColor Yellow
    Push-Location $mirrorPath

    # Limpiar remote github si existe de intento anterior
    & git remote remove github 2>$null
    & git remote add github "https://$GH_PAT@github.com/$GH_ORG/$repo.git"
    & git push --mirror github 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    $pushExit = $LASTEXITCODE
    Pop-Location

    if ($pushExit -ne 0) {
        Write-Host "    Push FALLO (exit code: $pushExit)" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status="PUSH_FAILED"; Detail="exit=$pushExit" }
        continue
    }
    Write-Host "    Push OK." -ForegroundColor Green

    # 4. Validar commit count
    Write-Host "  [4/4] Validando commits..." -ForegroundColor Yellow
    Push-Location $mirrorPath
    $srcCount = (& git rev-list --all --count 2>&1).Trim()
    Pop-Location

    $verifyPath = Join-Path $WORKDIR "${repo}_verify"
    if (Test-Path $verifyPath) { Remove-Item -Recurse -Force $verifyPath }
    & git clone "https://$GH_PAT@github.com/$GH_ORG/$repo.git" $verifyPath 2>&1 | Out-Null
    Push-Location $verifyPath
    $tgtCount = (& git rev-list --all --count 2>&1).Trim()
    Pop-Location
    Remove-Item -Recurse -Force $verifyPath -ErrorAction SilentlyContinue

    if ($srcCount -eq $tgtCount) {
        Write-Host "    VALIDADO: $srcCount commits en source = $tgtCount en target" -ForegroundColor Green
        $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status="OK"; Detail="$srcCount commits" }
    }
    else {
        Write-Host "    MISMATCH: source=$srcCount target=$tgtCount" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status="MISMATCH"; Detail="src=$srcCount tgt=$tgtCount" }
    }
}

# ============================================================
# PARTE 2: Repos TFVC (tip migration)
# ============================================================

Write-Host ""
Write-Host "========== PARTE 2: Repos TFVC (tip migration via ZIP) ==========" -ForegroundColor Cyan
Write-Host "  Estrategia: solo el ultimo estado del codigo." -ForegroundColor Yellow
Write-Host "  El historial de changesets queda en ADO Server." -ForegroundColor Yellow

foreach ($t in $tfvcRepos) {
    $project  = $t.Project
    $tfvcPath = $t.TfvcPath
    $gitName  = $t.GitName
    Write-Host ""
    Write-Host "--- [$project -> $gitName] ---" -ForegroundColor White

    # 1. Descargar ZIP via API
    Write-Host "  [1/5] Descargando contenido TFVC..." -ForegroundColor Yellow
    $downloadDir = Join-Path $WORKDIR "tfvc_$gitName"
    if (Test-Path $downloadDir) { Remove-Item -Recurse -Force $downloadDir }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    $zipPath = Join-Path $WORKDIR "tfvc_${gitName}.zip"
    $encodedPath = [System.Uri]::EscapeDataString($tfvcPath)
    $zipUrl = "$ADO_BASE/$project/_apis/tfvc/items?path=$encodedPath&`$format=zip&api-version=5.0"

    $webParams = @{
        Uri     = $zipUrl
        Method  = "Get"
        OutFile = $zipPath
    }
    if ($ADO_PAT) {
        $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$ADO_PAT"))
        $webParams["Headers"] = @{ Authorization = "Basic $base64Auth" }
    }
    else {
        $webParams["UseDefaultCredentials"] = $true
    }

    try {
        Invoke-WebRequest @webParams
        $zipSize = (Get-Item $zipPath).Length
        $zipSizeMB = [math]::Round($zipSize / 1MB, 2)
        Write-Host "    Descarga OK ($zipSizeMB MB)" -ForegroundColor Green
    }
    catch {
        Write-Host "    Error descargando: $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="DOWNLOAD_FAILED"; Detail=$_.Exception.Message }
        continue
    }

    # 2. Extraer ZIP
    Write-Host "  [2/5] Extrayendo archivos..." -ForegroundColor Yellow
    try {
        Expand-Archive -Path $zipPath -DestinationPath $downloadDir -Force
        Remove-Item $zipPath -ErrorAction SilentlyContinue
        $fileCount = @(Get-ChildItem -Path $downloadDir -Recurse -File).Count
        Write-Host "    Extraido: $fileCount archivos" -ForegroundColor Green
    }
    catch {
        Write-Host "    Error extrayendo ZIP: $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="EXTRACT_FAILED"; Detail=$_.Exception.Message }
        continue
    }

    if ($fileCount -eq 0) {
        Write-Host "    WARN: ZIP vacio, no hay archivos para migrar" -ForegroundColor Yellow
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="EMPTY"; Detail="0 files" }
        continue
    }

    # 3. Crear repo Git local
    Write-Host "  [3/5] Creando repo Git local..." -ForegroundColor Yellow
    Push-Location $downloadDir
    & git init 2>&1 | Out-Null
    & git checkout -b main 2>&1 | Out-Null
    & git add -A 2>&1 | Out-Null
    & git commit -m "Tip migration from TFVC: $tfvcPath ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))" 2>&1 | Out-Null
    Pop-Location
    Write-Host "    Repo Git local creado." -ForegroundColor Green

    # 4. Crear repo en GitHub y push
    Write-Host "  [4/5] Creando repo en GitHub y push..." -ForegroundColor Yellow
    $created = New-GitHubRepo -Org $GH_ORG -RepoName $gitName -Pat $GH_PAT
    if ($created -eq $false) {
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="GH_CREATE_FAILED"; Detail="" }
        Pop-Location -ErrorAction SilentlyContinue
        continue
    }

    Push-Location $downloadDir
    & git remote add origin "https://$GH_PAT@github.com/$GH_ORG/$gitName.git" 2>&1 | Out-Null
    & git push -u origin main 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    $pushExit = $LASTEXITCODE
    Pop-Location

    if ($pushExit -ne 0) {
        Write-Host "    Push FALLO (exit code: $pushExit)" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="PUSH_FAILED"; Detail="exit=$pushExit" }
        continue
    }
    Write-Host "    Push OK." -ForegroundColor Green

    # 5. Validar
    Write-Host "  [5/5] Validando..." -ForegroundColor Yellow
    Write-Host "    OK: $fileCount archivos migrados" -ForegroundColor Green
    $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="OK"; Detail="$fileCount files" }
}

# ============================================================
# RESUMEN
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  RESUMEN POC - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

foreach ($r in $results) {
    $color = "Green"
    if ($r.Status -ne "OK") { $color = "Red" }
    $line = "  [{0}] {1,-55} {2}  {3}" -f $r.Type, $r.Name, $r.Status, $r.Detail
    Write-Host $line -ForegroundColor $color
}

Write-Host ""
Write-Host "  Verificar en: https://github.com/orgs/$GH_ORG/repositories" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Exportar resumen a CSV
$csvPath = Join-Path $WORKDIR "poc_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding ASCII
Write-Host "  Resultados exportados a: $csvPath" -ForegroundColor Cyan
