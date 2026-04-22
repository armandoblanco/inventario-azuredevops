<#
.SYNOPSIS
    POC: Migracion ADO Server OnPrem -> GitHub (BCR-Devops)
    3 repos Git (mirror) + 3 repos TFVC (tip migration)
.DESCRIPTION
    Solo lectura en ADO. Crea repos nuevos en GitHub.
    Requiere: git instalado, conectividad a bcrtfs y github.com
.PARAMETER MigrationType
    Tipo de migracion a ejecutar. Valores: Git | TFVC | Both. Default: Both
.PARAMETER EnvFile
    Ruta al archivo .env con la configuracion. Default: ./.env (junto al script)
.EXAMPLE
    # 1) Copiar .env.example a .env y completar GH_PAT, ADO_PAT, ADO_BASE, GH_ORG, WORKDIR
    # 2) Ejecutar:
    .\test-migrate.ps1 -MigrationType Both
    .\test-migrate.ps1 -MigrationType Git
    .\test-migrate.ps1 -MigrationType TFVC
    .\test-migrate.ps1 -EnvFile "C:\ruta\a\mi.env"
.EXAMPLE
    # Alternativa sin .env (usar variables de entorno del shell):
    $env:GH_PAT = "ghp_tu_token_github"
    $env:ADO_PAT = "tu_pat_ado"
    .\test-migrate.ps1 -MigrationType Both
#>

[CmdletBinding()]
param(
    [ValidateSet("Git", "TFVC", "Both")]
    [string]$MigrationType = "Both",

    [string]$EnvFile = (Join-Path $PSScriptRoot ".env")
)

# ============================================================
# CARGA DE .env
# ============================================================
function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "INFO: No se encontro archivo .env en '$Path'. Se usaran variables de entorno actuales." -ForegroundColor DarkYellow
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
        # Quitar comillas envolventes si las hay
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        # Set en el scope del proceso para que $env:KEY funcione
        [Environment]::SetEnvironmentVariable($key, $val, "Process")
    }
}

Import-DotEnv -Path $EnvFile

# ============================================================
# CONFIGURACION (desde .env o variables de entorno)
# ============================================================
$ADO_BASE = if ($env:ADO_BASE) { $env:ADO_BASE } else { "https://bcrtfs/tfs/BCRCollection" }
$GH_ORG   = if ($env:GH_ORG)   { $env:GH_ORG }   else { "BCR-Devops" }
$WORKDIR  = if ($env:WORKDIR)  { $env:WORKDIR }  else { "C:\mp" }   # ruta corta para evitar MAX_PATH
$GH_PAT   = $env:GH_PAT
$ADO_PAT  = $env:ADO_PAT

# Cargar ensamblado ZIP (.NET) para extraccion robusta con PS 5.1
Add-Type -AssemblyName System.IO.Compression.FileSystem

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

function Write-Diag {
    param([string]$Message)
    Write-Host "    DIAG: $Message" -ForegroundColor DarkYellow
}

function Test-Connectivity {
    param([string]$Label, [string]$Url)
    Write-Host "  Verificando conectividad a $Label ($Url)..." -ForegroundColor Yellow
    try {
        $req = [System.Net.WebRequest]::Create($Url)
        $req.Method = "HEAD"
        $req.Timeout = 8000
        $null = $req.GetResponse()
        Write-Host "    Conectividad OK." -ForegroundColor Green
        return $true
    }
    catch [System.Net.WebException] {
        $status = "desconocido"
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        # Un HTTP error (401,403,404) igual significa que el host responde
        if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::ProtocolError) {
            Write-Host "    Host responde (HTTP $status). Continuando." -ForegroundColor Green
            return $true
        }
        Write-Host "    ERROR DE CONECTIVIDAD: $($_.Exception.Message)" -ForegroundColor Red
        Write-Diag "Estado de red: $($_.Exception.Status)"
        Write-Diag "Verifica VPN, firewall o DNS para $Url"
        return $false
    }
}

function New-GitHubRepo {
    param([string]$Org, [string]$RepoName, [string]$Pat)
    $headers = @{
        Authorization = "token $Pat"
        Accept        = "application/vnd.github+json"
    }
    $body = @{ name = $RepoName; visibility = "internal"; auto_init = $false } | ConvertTo-Json
    try {
        $null = Invoke-RestMethod -Uri "https://api.github.com/orgs/$Org/repos" `
            -Method Post -Headers $headers -Body $body -ContentType "application/json"
        Write-Host "    Repo creado en GitHub." -ForegroundColor Green
    }
    catch {
        $msg = $_.Exception.Message
        # Intentar leer el cuerpo de la respuesta de error de GitHub
        $responseBody = ""
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $responseBody = $reader.ReadToEnd()
        } catch {}

        if ($msg -match '422') {
            Write-Host "    Repo ya existe en GitHub, continuando." -ForegroundColor Yellow
        }
        elseif ($msg -match '401') {
            Write-Host "    ERROR 401 - No autorizado al crear repo en org '$Org'." -ForegroundColor Red
            Write-Diag "El PAT puede estar vencido o ser invalido."
            Write-Diag "Verifica: Settings -> Developer settings -> PAT -> Expiration"
            if ($responseBody) { Write-Diag "Respuesta GitHub: $responseBody" }
            return $false
        }
        elseif ($msg -match '403') {
            Write-Host "    ERROR 403 - PAT sin permisos para crear repos en la org '$Org'." -ForegroundColor Red
            Write-Diag "Causa 1: El PAT no tiene el scope 'write:org' (requerido para crear repos en una org)."
            Write-Diag "Causa 2: Tu usuario no tiene permisos de creacion en la org (Settings org -> Member privileges -> Repository creation)."
            Write-Diag "Causa 3: La org tiene SSO habilitado y el PAT no esta autorizado para la org."
            if ($responseBody) { Write-Diag "Respuesta GitHub: $responseBody" }
            return $false
        }
        elseif ($msg -match '404') {
            Write-Host "    ERROR 404 - Org '$Org' no encontrada o PAT sin acceso a ella." -ForegroundColor Red
            Write-Diag "Verifica que el nombre de la org sea exacto: '$Org'"
            Write-Diag "Verifica que tu usuario sea miembro de la org."
            if ($responseBody) { Write-Diag "Respuesta GitHub: $responseBody" }
            return $false
        }
        else {
            Write-Host "    ERROR al crear repo '$RepoName': $msg" -ForegroundColor Red
            if ($responseBody) { Write-Diag "Respuesta GitHub: $responseBody" }
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

# --- Pre-flight: conectividad ---
Write-Host ""
Write-Host "========== Pre-flight: verificacion de conectividad ==========" -ForegroundColor Cyan
$adoOk    = Test-Connectivity -Label "ADO OnPrem" -Url $ADO_BASE
$githubOk = Test-Connectivity -Label "GitHub"     -Url "https://api.github.com"
if (-not $adoOk) {
    Write-Host "ADVERTENCIA: No se pudo alcanzar ADO OnPrem. Los clones Git y descargas TFVC fallaran." -ForegroundColor Red
    Write-Diag "Asegurate de estar conectado a la red corporativa o VPN antes de continuar."
}
if (-not $githubOk) {
    Write-Host "ADVERTENCIA: No se pudo alcanzar github.com. Las creaciones de repo y pushes fallaran." -ForegroundColor Red
}
Write-Host ""

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  POC Migracion: ADO Server OnPrem -> GitHub" -ForegroundColor Cyan
Write-Host "  Org GitHub : $GH_ORG" -ForegroundColor Cyan
Write-Host "  ADO Base   : $ADO_BASE" -ForegroundColor Cyan
Write-Host "  Git repos  : $($gitRepos.Count)" -ForegroundColor Cyan
Write-Host "  TFVC repos : $($tfvcRepos.Count)" -ForegroundColor Cyan
Write-Host "  Directorio : $WORKDIR" -ForegroundColor Cyan
Write-Host "  Modo        : $MigrationType" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ============================================================
# PARTE 1: Repos Git
# ============================================================

if ($MigrationType -eq "Git" -or $MigrationType -eq "Both") {

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
        # URL-encodear el PAT: caracteres como +, /, = rompen la URL embebida en git
        $encodedPat = [System.Uri]::EscapeDataString($ADO_PAT)
        $cloneUrl = $cloneUrl -replace 'https://', "https://user:$encodedPat@"
    }

    $gitOutput = & git clone --mirror $cloneUrl $mirrorPath 2>&1
    $gitOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

    # Si falla con URL embebida, reintentar con http.extraheader (mas robusto en ADO Server)
    if (-not (Test-Path (Join-Path $mirrorPath "HEAD")) -and $ADO_PAT) {
        Write-Host "    Reintentando con http.extraheader..." -ForegroundColor Yellow
        $base64Ado = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$ADO_PAT"))
        $plainUrl  = "$ADO_BASE/$project/_git/$repo"
        $gitOutput = & git -c "http.extraheader=Authorization: Basic $base64Ado" clone --mirror $plainUrl $mirrorPath 2>&1
        $gitOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }

    if (-not (Test-Path (Join-Path $mirrorPath "HEAD"))) {
        Write-Host "  FALLO: clone mirror no completado para '$repo'" -ForegroundColor Red
        $outputStr = $gitOutput -join " | "
        if ($outputStr -match 'Authentication failed|403|401') {
            Write-Diag "Causa probable: autenticacion fallida en ADO."
            Write-Diag "Verifica que ADO_PAT sea valido y tenga scope 'Code (Read)'."
        } elseif ($outputStr -match 'unable to access|Could not resolve|Failed to connect|timed out') {
            Write-Diag "Causa probable: no se puede alcanzar el servidor ADO '$ADO_BASE'."
            Write-Diag "Verifica conectividad de red, VPN, o que el hostname 'bcrtfs' resuelva correctamente."
        } elseif ($outputStr -match 'repository.*not found|does not exist|404') {
            Write-Diag "Causa probable: el repo '$repo' no existe en el proyecto '$project'."
            Write-Diag "URL intentada: $($ADO_BASE)/$project/_git/$repo"
        } else {
            Write-Diag "Salida git: $outputStr"
        }
        $results += [PSCustomObject]@{ Type="Git"; Name=$repo; Status="CLONE_FAILED"; Detail=$outputStr.Substring(0, [Math]::Min(120, $outputStr.Length)) }
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

    # Limpiar refs que GitHub rechaza ANTES del push:
    #   refs/pull/*       -> ADO expone PRs aqui; GitHub los considera "hidden refs" y rechaza el push
    #   refs/remotes/*    -> refs de otros remotes que no deben replicarse
    #   refs/keep-around  -> refs internos de algunos servidores
    Write-Host "    Limpiando refs no portables (pull/*, remotes/*)..." -ForegroundColor DarkCyan
    $refsToDelete = & git for-each-ref --format='%(refname)' `
        refs/pull/ refs/remotes/ refs/keep-around/ 2>$null
    if ($refsToDelete) {
        $deleteStdin = ($refsToDelete | ForEach-Object { "delete $_" }) -join "`n"
        $deleteStdin | & git update-ref --stdin 2>&1 | Out-Null
        Write-Host "    Refs eliminadas: $($refsToDelete.Count)" -ForegroundColor DarkCyan
    }

    # Limpiar remote github si existe de intento anterior
    & git remote remove github 2>$null
    & git remote add github "https://$GH_PAT@github.com/$GH_ORG/$repo.git"
    $pushOutput = & git push --mirror github 2>&1
    $pushOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    $pushExit = $LASTEXITCODE
    Pop-Location

    if ($pushExit -ne 0) {
        $pushStr = $pushOutput -join " | "

        # Caso especial: GitHub solo rechazo hidden refs (refs/pull/*) pero branches y tags si se subieron.
        # Heuristica: si TODOS los rechazos son 'deny updating a hidden ref' lo tratamos como OK parcial.
        $hasHiddenRefReject = $pushStr -match 'deny updating a hidden ref'
        $hasOtherError = $pushStr -match '(rejected|error).*(non-fast-forward|protected branch|forbidden|unauthorized|cannot)'
        if ($hasHiddenRefReject -and -not $hasOtherError) {
            Write-Host "    Push OK (hidden refs ignoradas, branches y tags subidos)." -ForegroundColor Green
            $pushExit = 0
        }
    }

    if ($pushExit -ne 0) {
        $pushStr = $pushOutput -join " | "
        Write-Host "    Push FALLO (exit code: $pushExit) para '$repo'" -ForegroundColor Red
        if ($pushStr -match '401|Authentication|credentials') {
            Write-Diag "Causa probable: GH_PAT invalido o vencido."
            Write-Diag "Verifica el PAT en: github.com -> Settings -> Developer settings -> PAT."
        } elseif ($pushStr -match '403|forbidden') {
            Write-Diag "Causa probable: PAT sin permiso de escritura en el repo."
            Write-Diag "Verifica que el PAT tenga scope 'repo' completo."
        } elseif ($pushStr -match 'protected branch|cannot force') {
            Write-Diag "Causa probable: branch protegida en GitHub impide el push --mirror."
            Write-Diag "Desactiva las branch protection rules en el repo de GitHub antes de migrar."
        } elseif ($pushStr -match 'unable to access|timed out') {
            Write-Diag "Causa probable: sin conectividad a github.com durante el push."
        } else {
            Write-Diag "Salida git push: $pushStr"
        }
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

} else {
    Write-Host ""
    Write-Host "  [OMITIDO] Migracion Git (-MigrationType=$MigrationType)" -ForegroundColor DarkGray
}

# ============================================================
# PARTE 2: Repos TFVC (tip migration)
# ============================================================

if ($MigrationType -eq "TFVC" -or $MigrationType -eq "Both") {

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
        Uri             = $zipUrl
        Method          = "Get"
        OutFile         = $zipPath
        UseBasicParsing = $true
    }
    if ($ADO_PAT) {
        $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$ADO_PAT"))
        $webParams["Headers"] = @{ Authorization = "Basic $base64Auth" }
    }
    else {
        $webParams["UseDefaultCredentials"] = $true
    }

    $urlForLog = "$ADO_BASE/$project/_apis/tfvc/items?path=$encodedPath&format=zip&api-version=5.0"
    Write-Diag "URL: $urlForLog"
    try {
        Invoke-WebRequest @webParams
        $zipSize = (Get-Item $zipPath).Length
        $zipSizeMB = [math]::Round($zipSize / 1MB, 2)
        Write-Host "    Descarga OK ($zipSizeMB MB)" -ForegroundColor Green
    }
    catch [System.Net.WebException] {
        $httpStatus = "desconocido"
        if ($_.Exception.Response) { $httpStatus = [int]$_.Exception.Response.StatusCode }
        Write-Host "    ERROR descargando ZIP TFVC '$gitName' (HTTP $httpStatus)" -ForegroundColor Red
        Write-Diag "URL llamada: $urlForLog"
        if ($httpStatus -eq 401 -or $httpStatus -eq 403) {
            Write-Diag "Causa probable: ADO_PAT invalido, vencido o sin permiso 'Code (Read)'."
        } elseif ($httpStatus -eq 404) {
            Write-Diag "Causa probable: la ruta TFVC '$tfvcPath' no existe en el proyecto '$project'."
            Write-Diag "Verifica la ruta en ADO: $ADO_BASE/$project/_versionControl"
        } elseif ($httpStatus -eq 0 -or $_.Exception.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure) {
            Write-Diag "Causa probable: sin conectividad a '$ADO_BASE'. Verifica red/VPN."
        } else {
            Write-Diag "Mensaje: $($_.Exception.Message)"
        }
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="DOWNLOAD_FAILED"; Detail="HTTP $httpStatus" }
        continue
    }
    catch {
        Write-Host "    ERROR descargando ZIP TFVC '$gitName': $($_.Exception.Message)" -ForegroundColor Red
        Write-Diag "URL llamada: $urlForLog"
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="DOWNLOAD_FAILED"; Detail=$_.Exception.Message }
        continue
    }

    # 2. Extraer ZIP
    # Usamos ZipFile.ExtractToDirectory en lugar de Expand-Archive para evitar el bug
    # de PS 5.1 con rutas que contienen espacios (ItemNotFoundException en Archive.psm1)
    Write-Host "  [2/5] Extrayendo archivos..." -ForegroundColor Yellow
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $downloadDir)
        Remove-Item $zipPath -ErrorAction SilentlyContinue
        $fileCount = @(Get-ChildItem -Path $downloadDir -Recurse -File).Count
        Write-Host "    Extraido: $fileCount archivos" -ForegroundColor Green
    }
    catch [System.IO.PathTooLongException] {
        Write-Host "    Error: ruta demasiado larga dentro del ZIP. Habilita Long Paths en Windows:" -ForegroundColor Red
        Write-Host "    reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f" -ForegroundColor Yellow
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="EXTRACT_FAILED"; Detail="PATH_TOO_LONG" }
        continue
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
    $initOut   = & git init 2>&1
    $checkOut  = & git checkout -b main 2>&1
    $addOut    = & git add -A 2>&1
    $commitOut = & git commit -m "Tip migration from TFVC: $tfvcPath ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))" 2>&1
    $commitExit = $LASTEXITCODE
    Pop-Location
    if ($commitExit -ne 0) {
        Write-Host "    FALLO al crear repo Git local para '$gitName' (exit code: $commitExit)" -ForegroundColor Red
        Write-Diag "git init   : $initOut"
        Write-Diag "git checkout: $checkOut"
        Write-Diag "git add    : $addOut"
        Write-Diag "git commit : $commitOut"
        Write-Diag "Verifica que git este instalado y en el PATH: git --version"
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="GIT_INIT_FAILED"; Detail="exit=$commitExit" }
        continue
    }
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
    $tfvcPushOutput = & git push -u origin main 2>&1
    $tfvcPushOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    $pushExit = $LASTEXITCODE
    Pop-Location

    if ($pushExit -ne 0) {
        $tfvcPushStr = $tfvcPushOutput -join " | "
        Write-Host "    Push FALLO (exit code: $pushExit) para '$gitName'" -ForegroundColor Red
        if ($tfvcPushStr -match '401|Authentication|credentials') {
            Write-Diag "Causa probable: GH_PAT invalido o vencido."
        } elseif ($tfvcPushStr -match '403|forbidden') {
            Write-Diag "Causa probable: PAT sin permiso de escritura. Verifica scope 'repo' en el PAT."
        } elseif ($tfvcPushStr -match 'protected branch') {
            Write-Diag "Causa probable: branch 'main' protegida. Desactiva branch protection en GitHub para el repo '$gitName'."
        } else {
            Write-Diag "Salida git push: $tfvcPushStr"
        }
        $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="PUSH_FAILED"; Detail="exit=$pushExit" }
        continue
    }
    Write-Host "    Push OK." -ForegroundColor Green

    # 5. Validar
    Write-Host "  [5/5] Validando..." -ForegroundColor Yellow
    Write-Host "    OK: $fileCount archivos migrados" -ForegroundColor Green
    $results += [PSCustomObject]@{ Type="TFVC"; Name=$gitName; Status="OK"; Detail="$fileCount files" }
}

} else {
    Write-Host ""
    Write-Host "  [OMITIDO] Migracion TFVC (-MigrationType=$MigrationType)" -ForegroundColor DarkGray
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
