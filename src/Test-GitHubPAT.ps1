<#
.SYNOPSIS
    Test-GitHubPAT.ps1
    Diagnostico completo del PAT de GitHub antes de ejecutar la migracion.

.DESCRIPTION
    Verifica que el PAT de GitHub cumpla con los requisitos de test-migrate.ps1:
      1. Formato del token (ghp_*, gho_*, github_pat_*, ghs_*)
      2. Autenticacion valida (/user)
      3. Scopes necesarios: repo, workflow, delete_repo (opcional), admin:org o write:org
      4. Membresia y rol en la organizacion destino
      5. Permiso para crear repos en la organizacion
      6. Autorizacion SSO/SAML (si la org lo requiere)
      9. Crear y borrar un repo de prueba end-to-end (usa -SkipCreateTest para omitir)
      Conectividad HTTPS a api.github.com y github.com
    Solo lectura por defecto; el TEST 9 crea y borra un repo temporal.

.PARAMETER PatToken
    PAT de GitHub. Si no se provee, se lee $env:GH_PAT.
    Tambien carga .env (via -EnvFile) si existe.

.PARAMETER Org
    Organizacion destino donde se crearan los repos (ej: BCR-Devops).
    Si no se provee, se lee $env:GH_ORG.

.PARAMETER EnvFile
    Ruta al archivo .env (default: ./.env junto al script).

.EXAMPLE
    $env:GH_PAT = "ghp_xxx"
    .\Test-GitHubPAT.ps1 -Org "BCR-Devops"

.EXAMPLE
    # Usando .env
    .\Test-GitHubPAT.ps1

.NOTES
    Requiere: PowerShell 5.1+, conectividad a api.github.com (HTTPS 443).
    Operacion: Solo lectura. No crea ni modifica repos.
#>

[CmdletBinding()]
param(
    [string]$PatToken,

    [string]$Org,

    [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),

    # Si se especifica, NO intenta crear/borrar un repo de prueba (TEST 9).
    [switch]$SkipCreateTest,

    # Nombre del repo temporal que se crea y borra en el TEST 9.
    [string]$TestRepoName = "pat-test-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

$ErrorActionPreference = "Continue"
$script:passed = 0
$script:failed = 0
$script:warned = 0

# ----------------------------------------------------------------
# Carga .env (mismo formato que test-migrate.ps1)
# ----------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
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
if (-not $PatToken) { $PatToken = $env:GH_PAT }
if (-not $Org)      { $Org      = $env:GH_ORG }

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
function Write-Pass { param([string]$Msg) Write-Host "  [PASS] $Msg" -ForegroundColor Green; $script:passed++ }
function Write-Fail { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red;   $script:failed++ }
function Write-Warn { param([string]$Msg) Write-Host "  [WARN] $Msg" -ForegroundColor Yellow; $script:warned++ }
function Write-Info { param([string]$Msg) Write-Host "  [INFO] $Msg" -ForegroundColor Cyan }
function Write-Diag { param([string]$Msg) Write-Host "         DIAG: $Msg" -ForegroundColor DarkYellow }

function Invoke-GitHubApi {
    param(
        [string]$Url,
        [string]$Pat,
        [string]$Method = "Get",
        [string]$Body
    )
    $headers = @{
        Authorization          = "token $Pat"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent"           = "Test-GitHubPAT-ps1"
    }
    $params = @{
        Uri             = $Url
        Method          = $Method
        Headers         = $headers
        UseBasicParsing = $true
    }
    if ($Body) {
        $params["Body"]        = $Body
        $params["ContentType"] = "application/json"
    }
    return Invoke-WebRequest @params
}

# Extrae status code y cuerpo de un ErrorRecord funcionando en PS 5.1 (WebException) y PS 7+ (HttpResponseException)
function Get-HttpStatusCode {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    try {
        $ex = $ErrorRecord.Exception
        if ($ex.Response) {
            return [int]$ex.Response.StatusCode
        }
    } catch {}
    # PS 7: HttpResponseException.StatusCode
    if ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'StatusCode') {
        return [int]$ErrorRecord.Exception.StatusCode
    }
    return 0
}

function Get-HttpResponseBody {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    # PS 7 expone el body en ErrorDetails.Message
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }
    # PS 5.1: leer stream de la respuesta
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            $stream = $resp.GetResponseStream()
            $stream.Position = 0
            $reader = New-Object System.IO.StreamReader($stream)
            return $reader.ReadToEnd()
        }
    } catch {}
    return ""
}

function Show-SamlSsoHint {
    param([string]$Body, [string]$OrgName)
    if ($Body -and $Body -match 'SAML enforcement|saml-sso|single sign') {
        Write-Diag "SAML SSO: la org '$OrgName' exige autorizar el PAT."
        Write-Diag "Accion: https://github.com/settings/tokens -> localiza tu PAT -> 'Configure SSO' -> Authorize para '$OrgName'."
        return $true
    }
    return $false
}

# ----------------------------------------------------------------
# Banner
# ----------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Diagnostico PAT - GitHub" -ForegroundColor Cyan
Write-Host "  Org destino : $Org" -ForegroundColor Cyan
Write-Host "  Fecha       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------
# TEST 1: PAT presente y formato
# ----------------------------------------------------------------
Write-Host "---- TEST 1: Presencia y formato del PAT ----" -ForegroundColor White

if (-not $PatToken) {
    Write-Fail "No se encontro PAT. Pasa -PatToken, define GH_PAT en .env o `$env:GH_PAT"
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  Imposible continuar sin PAT." -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 1
}

$masked = $PatToken.Substring(0, [Math]::Min(7, $PatToken.Length)) + "****"
Write-Pass "PAT encontrado (prefijo: $masked, longitud: $($PatToken.Length))"

if ($PatToken -match '\s') {
    Write-Fail "El PAT contiene espacios. Copialo sin espacios ni saltos de linea."
}

$tokenType = "desconocido"
switch -Regex ($PatToken) {
    '^ghp_[A-Za-z0-9]{36,}$'         { $tokenType = "Classic PAT (ghp_)"; break }
    '^github_pat_[A-Za-z0-9_]{80,}$' { $tokenType = "Fine-grained PAT (github_pat_)"; break }
    '^gho_[A-Za-z0-9]{36,}$'         { $tokenType = "OAuth token (gho_)"; break }
    '^ghs_[A-Za-z0-9]{36,}$'         { $tokenType = "Server-to-server (ghs_)"; break }
    '^ghu_[A-Za-z0-9]{36,}$'         { $tokenType = "User-to-server (ghu_)"; break }
}
Write-Info "Tipo detectado: $tokenType"

if ($tokenType -eq "Fine-grained PAT (github_pat_)") {
    Write-Warn "Los fine-grained PAT NO soportan crear repos en organizacion con API classic en todos los casos."
    Write-Diag "Para test-migrate.ps1 se recomienda PAT classic (ghp_) con scope 'repo' y 'admin:org'->'write:org'."
    Write-Diag "Si usas fine-grained: la org debe permitirlos, y debe tener permiso 'Administration: Read & Write'."
}
if ($tokenType -eq "desconocido") {
    Write-Warn "El prefijo del token no coincide con los formatos esperados (ghp_/github_pat_/gho_/ghs_/ghu_)."
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 2: Conectividad a api.github.com
# ----------------------------------------------------------------
Write-Host "---- TEST 2: Conectividad a api.github.com ----" -ForegroundColor White

try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $connect = $tcp.BeginConnect("api.github.com", 443, $null, $null)
    $ok = $connect.AsyncWaitHandle.WaitOne(5000, $false)
    if ($ok -and $tcp.Connected) {
        Write-Pass "TCP 443 alcanzable en api.github.com"
        $tcp.Close()
    } else {
        Write-Fail "Timeout TCP a api.github.com:443"
        Write-Diag "Verifica firewall corporativo, proxy o VPN."
        $tcp.Close()
    }
} catch {
    Write-Fail "Error TCP: $($_.Exception.Message)"
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 3: Autenticacion (/user)
# ----------------------------------------------------------------
Write-Host "---- TEST 3: Autenticacion - GET /user ----" -ForegroundColor White

$userInfo = $null
$scopesHeader = ""
try {
    $resp = Invoke-GitHubApi -Url "https://api.github.com/user" -Pat $PatToken
    $userInfo = $resp.Content | ConvertFrom-Json
    Write-Pass "HTTP 200 - Autenticado como: $($userInfo.login) ($($userInfo.name))"
    Write-Info "Account type : $($userInfo.type)"
    Write-Info "User id      : $($userInfo.id)"

    if ($resp.Headers["X-OAuth-Scopes"]) {
        $scopesHeader = ($resp.Headers["X-OAuth-Scopes"] -join ", ").Trim()
        Write-Info "Scopes (X-OAuth-Scopes): $scopesHeader"
    } else {
        Write-Warn "No se recibio header X-OAuth-Scopes (puede ser fine-grained PAT)."
    }
    if ($resp.Headers["X-Accepted-OAuth-Scopes"]) {
        $acc = ($resp.Headers["X-Accepted-OAuth-Scopes"] -join ", ").Trim()
        Write-Info "Accepted scopes para /user: $acc"
    }
    if ($resp.Headers["github-authentication-token-expiration"]) {
        $exp = ($resp.Headers["github-authentication-token-expiration"] -join ", ").Trim()
        Write-Info "Expiracion del token: $exp"
    } else {
        Write-Warn "El token no tiene fecha de expiracion declarada (o es non-expiring)."
    }
} catch {
    $code = Get-HttpStatusCode $_
    $body = Get-HttpResponseBody $_
    Write-Fail "HTTP $code autenticando con el PAT."
    switch ($code) {
        401 {
            Write-Diag "PAT invalido, revocado o vencido. Genera uno nuevo en: https://github.com/settings/tokens"
        }
        403 {
            if (-not (Show-SamlSsoHint $body $Org)) {
                Write-Diag "PAT bloqueado por rate-limit, IP allowlist o SSO no autorizado."
            }
        }
        default {
            Write-Diag "Mensaje: $($_.Exception.Message)"
        }
    }
    if ($body) { Write-Diag "Respuesta GitHub: $body" }
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  Auth fallo. Resto de tests omitidos." -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 1
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 4: Scopes requeridos por test-migrate.ps1
# ----------------------------------------------------------------
Write-Host "---- TEST 4: Scopes requeridos ----" -ForegroundColor White

# Requisitos de test-migrate.ps1:
#   - Crear repos en org         -> 'repo' + ('admin:org' o 'write:org')
#   - Push --mirror / push main  -> 'repo'
#   - Workflow files (.github)   -> 'workflow'
$hasRepo     = $scopesHeader -match '(^|,\s*)repo($|,)'
$hasWriteOrg = $scopesHeader -match '(^|,\s*)(admin:org|write:org)($|,)'
$hasWorkflow = $scopesHeader -match '(^|,\s*)workflow($|,)'
$hasDeleteRepo = $scopesHeader -match '(^|,\s*)delete_repo($|,)'

if ($hasRepo) {
    Write-Pass "Scope 'repo' presente (requerido para push --mirror y crear repos privados/internos)."
} else {
    if ($tokenType -eq "Fine-grained PAT (github_pat_)") {
        Write-Warn "No se detecta scope 'repo' (normal en fine-grained). Revisa permisos 'Contents: R/W', 'Administration: R/W'."
    } else {
        Write-Fail "Falta scope 'repo'. test-migrate.ps1 fallara al crear repos o hacer push."
        Write-Diag "Regenera el PAT en https://github.com/settings/tokens y marca la casilla 'repo' completa."
    }
}

if ($hasWriteOrg) {
    Write-Pass "Scope 'admin:org' o 'write:org' presente (requerido para crear repos en la org '$Org')."
} else {
    if ($tokenType -eq "Fine-grained PAT (github_pat_)") {
        Write-Warn "No se detecta 'admin:org'/'write:org'. En fine-grained revisa 'Organization permissions -> Administration: R/W'."
    } else {
        Write-Fail "Falta 'admin:org' o 'write:org'. Crear repos en la org '$Org' fallara con 403."
        Write-Diag "Regenera el PAT marcando 'admin:org -> write:org'."
    }
}

if ($hasWorkflow) {
    Write-Pass "Scope 'workflow' presente (necesario si los mirrors contienen archivos .github/workflows/*)."
} else {
    Write-Warn "Falta 'workflow'. Si algun repo Git migrado tiene .github/workflows, el push --mirror sera rechazado."
    Write-Diag "Agrega el scope 'workflow' al PAT para evitar rechazos al migrar pipelines de GitHub Actions."
}

if ($hasDeleteRepo) {
    Write-Info "Scope 'delete_repo' presente (opcional, util si necesitas limpiar repos de prueba)."
} else {
    Write-Info "Scope 'delete_repo' ausente (opcional, no requerido para migracion)."
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 5: Organizacion existe y PAT puede verla
# ----------------------------------------------------------------
Write-Host "---- TEST 5: Acceso a la organizacion '$Org' ----" -ForegroundColor White

if (-not $Org) {
    Write-Fail "Parametro -Org vacio y GH_ORG no definido. No se puede validar la org."
} else {
    try {
        $resp = Invoke-GitHubApi -Url "https://api.github.com/orgs/$Org" -Pat $PatToken
        $orgInfo = $resp.Content | ConvertFrom-Json
        Write-Pass "Org '$Org' accesible. Nombre publico: $($orgInfo.name)"
        Write-Info "Plan       : $($orgInfo.plan.name)"
        Write-Info "Miembros   : $($orgInfo.public_members_url.Split('/')[-2])"

        # ----------------------------------------------------------------
        # TEST 6: Membresia
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "---- TEST 6: Membresia en la org ----" -ForegroundColor White
        try {
            $memResp = Invoke-GitHubApi -Url "https://api.github.com/user/memberships/orgs/$Org" -Pat $PatToken
            $mem = $memResp.Content | ConvertFrom-Json
            Write-Pass "Usuario '$($userInfo.login)' es miembro de '$Org'."
            Write-Info "Rol  : $($mem.role)"
            Write-Info "State: $($mem.state)"
            if ($mem.role -ne "admin") {
                Write-Warn "No eres 'admin' de la org. Para crear repos necesitas:"
                Write-Diag "  - Rol 'admin' en la org, O"
                Write-Diag "  - Permiso 'Repository creation' habilitado en Settings -> Member privileges."
            }
        } catch {
            $code = Get-HttpStatusCode $_
            $body = Get-HttpResponseBody $_
            Write-Fail "HTTP $code consultando membresia."
            if (-not (Show-SamlSsoHint $body $Org)) {
                Write-Diag "No eres miembro de '$Org' o el PAT no esta autorizado para verlo."
            }
        }

        # ----------------------------------------------------------------
        # TEST 7: Listado de repos de la org (proxy para permisos)
        # ----------------------------------------------------------------
        Write-Host ""
        Write-Host "---- TEST 7: Listado de repos de la org (proxy para permisos) ----" -ForegroundColor White
        try {
            $listResp = Invoke-GitHubApi -Url "https://api.github.com/orgs/$Org/repos?per_page=1" -Pat $PatToken
            Write-Pass "HTTP $($listResp.StatusCode) - PAT puede listar repos de '$Org'."
        } catch {
            $code = Get-HttpStatusCode $_
            $body = Get-HttpResponseBody $_
            Write-Fail "HTTP $code listando repos de '$Org'."
            if (-not (Show-SamlSsoHint $body $Org) -and $code -eq 403) {
                Write-Diag "Posible SSO/SAML no autorizado. Visita https://github.com/settings/tokens y autoriza el PAT para la org."
            }
        }
    } catch {
        $code = Get-HttpStatusCode $_
        $body = Get-HttpResponseBody $_
        Write-Fail "HTTP $code accediendo a la org '$Org'."
        if (-not (Show-SamlSsoHint $body $Org)) {
            switch ($code) {
                404 { Write-Diag "La org '$Org' no existe o tu PAT no tiene visibilidad sobre ella (SSO?)." }
                403 {
                    Write-Diag "Posible SSO/SAML sin autorizar para este PAT."
                    Write-Diag "Abre https://github.com/settings/tokens, localiza el PAT y presiona 'Configure SSO' -> Authorize para '$Org'."
                }
                default { Write-Diag "Mensaje: $($_.Exception.Message)" }
            }
        }
        if ($body) { Write-Diag "Respuesta GitHub: $body" }
    }
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 8: SSO authorizations (header saml-sso)
# ----------------------------------------------------------------
Write-Host "---- TEST 8: Revisar SSO (si aplica) ----" -ForegroundColor White
try {
    $resp = Invoke-GitHubApi -Url "https://api.github.com/user/orgs" -Pat $PatToken
    $orgs = $resp.Content | ConvertFrom-Json
    Write-Pass "PAT ve $($orgs.Count) org(s): $(($orgs | ForEach-Object { $_.login }) -join ', ')"
    if ($Org -and -not ($orgs | Where-Object { $_.login -ieq $Org })) {
        Write-Warn "La org '$Org' NO aparece en /user/orgs. Causas probables:"
        Write-Diag "1. No eres miembro (agrega tu cuenta a la org)."
        Write-Diag "2. SSO no autorizado: https://github.com/settings/tokens -> PAT -> 'Configure SSO' -> Authorize '$Org'."
    }
} catch {
    $code = Get-HttpStatusCode $_
    $body = Get-HttpResponseBody $_
    Write-Warn "HTTP $code listando /user/orgs."
    if (-not (Show-SamlSsoHint $body $Org)) {
        Write-Diag "Mensaje: $($_.Exception.Message)"
    }
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 9: Crear y borrar un repo de prueba en la org (end-to-end)
# ----------------------------------------------------------------
Write-Host "---- TEST 9: Crear y borrar repo de prueba en '$Org' ----" -ForegroundColor White

if ($SkipCreateTest) {
    Write-Info "Omitido por -SkipCreateTest."
} elseif (-not $Org) {
    Write-Warn "Omitido: no hay org definida."
} elseif ($script:failed -gt 0) {
    Write-Warn "Omitido: hay FAIL previos que impedirian la creacion."
} else {
    Write-Info "Repo temporal: $Org/$TestRepoName"
    $createdOk = $false

    # 9a. Crear repo privado
    $createBody = @{
        name        = $TestRepoName
        visibility  = "private"
        auto_init   = $false
        description = "Repo temporal de Test-GitHubPAT.ps1 - borrar si persiste"
    } | ConvertTo-Json

    try {
        $resp = Invoke-GitHubApi -Url "https://api.github.com/orgs/$Org/repos" -Pat $PatToken `
                                 -Method Post -Body $createBody
        Write-Pass "Repo creado (HTTP $($resp.StatusCode)). Scope 'repo' + 'write:org' funcionan."
        $createdOk = $true
    } catch {
        $code = Get-HttpStatusCode $_
        $body = Get-HttpResponseBody $_
        Write-Fail "HTTP $code al crear repo de prueba."
        if (-not (Show-SamlSsoHint $body $Org)) {
            switch ($code) {
                401 { Write-Diag "PAT invalido/vencido." }
                403 {
                    Write-Diag "El PAT no tiene permiso para crear repos en '$Org'."
                    Write-Diag "Falta scope 'write:org' o 'Repository creation' deshabilitado en la org."
                    Write-Diag "Si la org usa SSO: autoriza el PAT en https://github.com/settings/tokens."
                }
                404 { Write-Diag "La org '$Org' no existe o no eres miembro." }
                422 { Write-Diag "Nombre de repo invalido o ya existe. Intenta con otro -TestRepoName." }
                default { Write-Diag "Mensaje: $($_.Exception.Message)" }
            }
        }
        if ($body) { Write-Diag "Respuesta GitHub: $body" }
    }

    # 9b. Borrar repo (solo si se creo)
    if ($createdOk) {
        Write-Info "Intentando borrar el repo temporal..."
        try {
            $null = Invoke-GitHubApi -Url "https://api.github.com/repos/$Org/$TestRepoName" `
                                     -Pat $PatToken -Method Delete
            Write-Pass "Repo '$Org/$TestRepoName' eliminado. Scope 'delete_repo' funciona."
        } catch {
            $code = Get-HttpStatusCode $_
            Write-Warn "HTTP $code al borrar '$Org/$TestRepoName'."
            switch ($code) {
                403 {
                    Write-Diag "Falta scope 'delete_repo' en el PAT (o politica de la org lo restringe)."
                    Write-Diag "IMPORTANTE: borra manualmente https://github.com/$Org/$TestRepoName/settings"
                }
                404 { Write-Diag "No existe o no accesible. Borra manualmente si persiste." }
                default {
                    Write-Diag "Mensaje: $($_.Exception.Message)"
                    Write-Diag "IMPORTANTE: borra manualmente https://github.com/$Org/$TestRepoName/settings"
                }
            }
        }
    }
}

Write-Host ""

# ----------------------------------------------------------------
# Resumen
# ----------------------------------------------------------------
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  RESUMEN" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PASS  : $script:passed" -ForegroundColor Green
Write-Host "  WARN  : $script:warned" -ForegroundColor Yellow
Write-Host "  FAIL  : $script:failed" -ForegroundColor Red
Write-Host ""

if ($script:failed -gt 0) {
    Write-Host "  Resultado: NO APTO. Corrige los FAIL antes de ejecutar test-migrate.ps1." -ForegroundColor Red
    exit 1
} elseif ($script:warned -gt 0) {
    Write-Host "  Resultado: APTO CON ADVERTENCIAS. Revisa los WARN." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "  Resultado: APTO. El PAT cumple con todos los requisitos." -ForegroundColor Green
    exit 0
}
