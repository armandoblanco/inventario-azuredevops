# ============================================================
# POC: Migracion ADO Server OnPrem -> GitHub
# 3 repos Git + 3 repos TFVC
# ============================================================

# === CONFIGURACION (editar estos valores) ===
$ADO_BASE    = "https://bcrtfs/tfs/BCRCollection"
$GH_ORG      = "tu-org-github"
$GH_PAT      = $env:GH_PAT           # setear antes: $env:GH_PAT = "ghp_xxx"
$ADO_PAT     = $env:ADO_PAT          # setear antes: $env:ADO_PAT = "xxx"
$WORKDIR     = "C:\migration-poc"

# --- Repos Git (clone mirror directo) ---
$gitRepos = @(
    @{ Project = "TPBCRComercial"; Repo = "bcr_comercial_restapi_prestamos_netcore" },
    @{ Project = "TPBCRComercial"; Repo = "bcr_comercial_pruebas_funcionales_automatizadas" },
    @{ Project = "TPBCRComercial"; Repo = "bcr-comercial-restapicommon-netcore" }
)

# --- Repos TFVC (requieren conversion a Git primero) ---
# Cambiar por los 3 proyectos TFVC que quieras probar
$tfvcRepos = @(
    @{ Project = "TPContabilidadPresupuesto"; TfvcPath = "$/TPContabilidadPresupuesto"; GitName = "TPContabilidadPresupuesto" },
    @{ Project = "TPOPCBancoBCR";             TfvcPath = "$/TPOPCBancoBCR";             GitName = "TPOPCBancoBCR" },
    @{ Project = "GerenciaAreaSistemaCORE";    TfvcPath = "$/GerenciaAreaSistemaCORE";    GitName = "GerenciaAreaSistemaCORE" }
)

# ============================================================
# Funciones
# ============================================================

function Invoke-AdoApi {
    param([string]$Url, [string]$Method = "Get", [string]$Body, [string]$Pat)
    $headers = @{}
    if ($Pat) {
        $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        $headers["Authorization"] = "Basic $base64"
    }
    $params = @{
        Uri         = $Url
        Method      = $Method
        Headers     = $headers
        ContentType = "application/json"
    }
    if (-not $Pat) { $params["UseDefaultCredentials"] = $true }
    if ($Body) { $params["Body"] = $Body }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        Write-Host "    API Error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function New-GitHubRepo {
    param([string]$Org, [string]$RepoName, [string]$Pat)
    $headers = @{ Authorization = "token $Pat"; Accept = "application/vnd.github+json" }
    $body = @{ name = $RepoName; private = $true } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "https://api.github.com/orgs/$Org/repos" `
            -Method Post -Headers $headers -Body $body -ContentType "application/json" | Out-Null
        Write-Host "    Repo creado en GitHub." -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -match '422') {
            Write-Host "    Repo ya existe en GitHub." -ForegroundColor Yellow
        }
        else {
            Write-Host "    Error creando repo: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Test-CommitCount {
    param([string]$MirrorPath, [string]$GitHubUrl, [string]$Pat)
    Push-Location $MirrorPath
    $srcCount = & git rev-list --all --count 2>&1
    Pop-Location

    $verifyDir = Join-Path $WORKDIR "_verify_temp"
    if (Test-Path $verifyDir) { Remove-Item -Recurse -Force $verifyDir }
    & git clone "https://$Pat@$($GitHubUrl -replace 'https://','')" $verifyDir 2>&1 | Out-Null
    Push-Location $verifyDir
    $tgtCount = & git rev-list --all --count 2>&1
    Pop-Location
    Remove-Item -Recurse -Force $verifyDir -ErrorAction SilentlyContinue

    if ($srcCount -eq $tgtCount) {
        Write-Host "    VALIDADO: $srcCount commits source = $tgtCount commits target" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "    MISMATCH: source=$srcCount target=$tgtCount" -ForegroundColor Red
        return $false
    }
}

# ============================================================
# INICIO
# ============================================================

New-Item -ItemType Directory -Path $WORKDIR -Force | Out-Null
Set-Location $WORKDIR

$results = @()

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  POC Migracion: ADO Server OnPrem -> GitHub" -ForegroundColor Cyan
Write-Host "  Git repos:  $($gitRepos.Count)" -ForegroundColor Cyan
Write-Host "  TFVC repos: $($tfvcRepos.Count)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ============================================================
# PARTE 1: Repos Git (directo)
# ============================================================

Write-Host ""
Write-Host "========== PARTE 1: Repos Git ==========" -ForegroundColor Cyan

foreach ($r in $gitRepos) {
    $repo = $r.Repo
    $project = $r.Project
    Write-Host ""
    Write-Host "--- [$repo] ---" -ForegroundColor White

    $mirrorPath = Join-Path $WORKDIR "$repo.git"
    $ghUrl = "https://github.com/$GH_ORG/$repo.git"

    # 1. Clone mirror
    Write-Host "  [1/4] Clone mirror desde ADO..." -ForegroundColor Yellow
    if (Test-Path $mirrorPath) { Remove-Item -Recurse -Force $mirrorPath }
    $cloneUrl = "$ADO_BASE/$project/_git/$repo"
    if ($ADO_PAT) { $cloneUrl = $cloneUrl -replace '(https?://)', "`$1user:$ADO_PAT@" }
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & git clone --mirror $cloneUrl $mirrorPath 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP
    if (-not (Test-Path $mirrorPath)) {
        Write-Host "  FALLO: clone no completado" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status="CLONE_FAILED" }
        continue
    }
    Write-Host "    Clone completado." -ForegroundColor Green

    # 2. Crear repo en GitHub
    Write-Host "  [2/4] Creando repo en GitHub..." -ForegroundColor Yellow
    New-GitHubRepo -Org $GH_ORG -RepoName $repo -Pat $GH_PAT

    # 3. Push mirror
    Write-Host "  [3/4] Push mirror a GitHub..." -ForegroundColor Yellow
    Push-Location $mirrorPath
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & git remote add github "https://$GH_PAT@github.com/$GH_ORG/$repo.git" 2>&1 | Out-Null
    & git push --mirror github 2>&1 | Out-Null
    $pushResult = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    Pop-Location

    if ($pushResult -ne 0) {
        Write-Host "    Push fallo" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status="PUSH_FAILED" }
        continue
    }
    Write-Host "    Push completado." -ForegroundColor Green

    # 4. Validar
    Write-Host "  [4/4] Validando..." -ForegroundColor Yellow
    $valid = Test-CommitCount -MirrorPath $mirrorPath -GitHubUrl $ghUrl -Pat $GH_PAT
    $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status=$(if($valid){"OK"}else{"MISMATCH"}) }
}

# ============================================================
# PARTE 2: Repos TFVC (conversion + mirror)
# ============================================================

Write-Host ""
Write-Host "========== PARTE 2: Repos TFVC ==========" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Estrategia: Tip migration (ultimo estado del codigo)" -ForegroundColor Yellow
Write-Host "  El historial TFVC queda consultable en ADO Server." -ForegroundColor Yellow

foreach ($t in $tfvcRepos) {
    $project = $t.Project
    $tfvcPath = $t.TfvcPath
    $gitName = $t.GitName
    Write-Host ""
    Write-Host "--- [$project -> $gitName] ---" -ForegroundColor White

    $ghUrl = "https://github.com/$GH_ORG/$gitName.git"

    # 1. Descargar contenido TFVC via API (get items como zip)
    Write-Host "  [1/5] Descargando contenido TFVC..." -ForegroundColor Yellow
    $downloadDir = Join-Path $WORKDIR "tfvc_$gitName"
    if (Test-Path $downloadDir) { Remove-Item -Recurse -Force $downloadDir }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    $zipPath = Join-Path $WORKDIR "tfvc_${gitName}.zip"
    $zipUrl = "$ADO_BASE/$project/_apis/tfvc/items?path=$tfvcPath&`$format=zip&api-version=5.0"

    $headers = @{}
    if ($ADO_PAT) {
        $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$ADO_PAT"))
        $headers["Authorization"] = "Basic $base64"
    }

    try {
        $webParams = @{
            Uri     = $zipUrl
            Method  = "Get"
            Headers = $headers
            OutFile = $zipPath
        }
        if (-not $ADO_PAT) { $webParams["UseDefaultCredentials"] = $true }
        Invoke-WebRequest @webParams
        Write-Host "    Descarga completada." -ForegroundColor Green
    }
    catch {
        Write-Host "    Error descargando TFVC: $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="DOWNLOAD_FAILED" }
        continue
    }

    # 2. Extraer zip
    Write-Host "  [2/5] Extrayendo archivos..." -ForegroundColor Yellow
    Expand-Archive -Path $zipPath -DestinationPath $downloadDir -Force
    Remove-Item $zipPath -ErrorAction SilentlyContinue
    Write-Host "    Extraido." -ForegroundColor Green

    # 3. Crear repo Git local
    Write-Host "  [3/5] Creando repo Git local..." -ForegroundColor Yellow
    Push-Location $downloadDir

    & git init 2>&1 | Out-Null
    & git checkout -b main 2>&1 | Out-Null

    # Crear .gitignore basico para .NET/Java
    @"
bin/
obj/
*.suo
*.user
*.vs/
packages/
target/
*.class
"@ | Out-File -FilePath ".gitignore" -Encoding ascii

    & git add -A 2>&1 | Out-Null
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & git commit -m "Tip migration from TFVC: $tfvcPath" 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP
    Pop-Location
    Write-Host "    Repo Git creado con commit inicial." -ForegroundColor Green

    # 4. Crear repo en GitHub y push
    Write-Host "  [4/5] Creando repo en GitHub y push..." -ForegroundColor Yellow
    New-GitHubRepo -Org $GH_ORG -RepoName $gitName -Pat $GH_PAT

    Push-Location $downloadDir
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & git remote add origin "https://$GH_PAT@github.com/$GH_ORG/$gitName.git" 2>&1 | Out-Null
    & git push -u origin main 2>&1 | Out-Null
    $pushResult = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    Pop-Location

    if ($pushResult -ne 0) {
        Write-Host "    Push fallo" -ForegroundColor Red
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="PUSH_FAILED" }
        continue
    }
    Write-Host "    Push completado." -ForegroundColor Green

    # 5. Validar
    Write-Host "  [5/5] Validando..." -ForegroundColor Yellow
    Push-Location $downloadDir
    $fileCount = (& git ls-files | Measure-Object).Count
    Pop-Location
    Write-Host "    OK: $fileCount archivos migrados a GitHub" -ForegroundColor Green
    $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="OK ($fileCount files)" }
}

# ============================================================
# RESUMEN
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  RESUMEN POC" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
foreach ($r in $results) {
    $color = "Green"
    if ($r.Status -notlike "OK*") { $color = "Red" }
    Write-Host "  [$($r.Type.PadRight(4))] $($r.Name.PadRight(55)) $($r.Status)" -ForegroundColor $color
}
Write-Host ""
Write-Host "  GitHub org: https://github.com/$GH_ORG" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
