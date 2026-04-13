<#
.SYNOPSIS
    Test-AdoPat.ps1
    Diagnostico completo del PAT de Azure DevOps Server OnPrem.

.DESCRIPTION
    Verifica conectividad, autenticacion y permisos del PAT de ADO Server
    antes de ejecutar la migracion. No modifica nada en el servidor.

.PARAMETER AdoBaseUrl
    URL base de la collection. Ejemplo: https://bcrtfs/tfs/BCRCollection

.PARAMETER PatToken
    PAT de ADO Server. Si no se provee, usa $env:ADO_PAT

.PARAMETER Project
    Proyecto de prueba para validar acceso a repos Git y TFVC.
    Default: TPBCRComercial

.PARAMETER GitRepo
    Nombre de un repo Git dentro del proyecto de prueba.
    Default: bcr_comercial_restapi_prestamos_netcore

.EXAMPLE
    $env:ADO_PAT = "tu_pat_ado"
    .\Test-AdoPat.ps1 -AdoBaseUrl "https://bcrtfs/tfs/BCRCollection"

.EXAMPLE
    .\Test-AdoPat.ps1 -AdoBaseUrl "https://bcrtfs/tfs/BCRCollection" `
        -PatToken "tu_pat_ado" -Project "TPBCRComercial" -GitRepo "bcr_comercial_restapi_prestamos_netcore"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdoBaseUrl,

    [string]$PatToken = $env:ADO_PAT,

    [string]$Project = "TPBCRComercial",

    [string]$GitRepo = "bcr_comercial_restapi_prestamos_netcore"
)

$ErrorActionPreference = "Continue"
$passed = 0
$failed = 0

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------

function Write-Pass { param([string]$Msg)
    Write-Host "  [PASS] $Msg" -ForegroundColor Green
    $script:passed++
}

function Write-Fail { param([string]$Msg)
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
    $script:failed++
}

function Write-Info { param([string]$Msg)
    Write-Host "  [INFO] $Msg" -ForegroundColor Cyan
}

function Write-Diag { param([string]$Msg)
    Write-Host "         DIAG: $Msg" -ForegroundColor DarkYellow
}

function Invoke-AdoApi {
    param([string]$Url, [string]$Pat, [switch]$UseDefaultCredentials)

    $headers = @{}
    if ($Pat) {
        $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        $headers["Authorization"] = "Basic $base64"
    }

    $params = @{
        Uri             = $Url
        Method          = "Get"
        Headers         = $headers
        ContentType     = "application/json"
        UseBasicParsing = $true
    }
    if ($UseDefaultCredentials) { $params["UseDefaultCredentials"] = $true }

    $response = Invoke-WebRequest @params
    return $response
}

# ----------------------------------------------------------------
# Banner
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Diagnostico PAT - Azure DevOps Server OnPrem" -ForegroundColor Cyan
Write-Host "  Collection : $AdoBaseUrl" -ForegroundColor Cyan
Write-Host "  Proyecto   : $Project" -ForegroundColor Cyan
Write-Host "  Repo Git   : $GitRepo" -ForegroundColor Cyan
Write-Host "  Fecha      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------
# TEST 1: PAT presente
# ----------------------------------------------------------------

Write-Host "---- TEST 1: Presencia del PAT ----" -ForegroundColor White

if (-not $PatToken) {
    Write-Fail "No se encontro PAT. Pasa -PatToken o ejecuta: `$env:ADO_PAT = 'tu_pat'"
    Write-Diag "Sin PAT el script usara autenticacion Windows (NTLM), que puede fallar fuera del dominio."
} else {
    $maskedPat = $PatToken.Substring(0, [Math]::Min(4, $PatToken.Length)) + "****"
    Write-Pass "PAT encontrado (primeros 4 chars: $maskedPat)"
    Write-Info "Longitud del PAT: $($PatToken.Length) caracteres"
    if ($PatToken.Length -lt 20) {
        Write-Fail "El PAT parece muy corto. Los PAT de ADO/TFS suelen tener 52 caracteres."
    }
    if ($PatToken -match '\s') {
        Write-Fail "El PAT contiene espacios. Copia el token sin espacios al inicio ni al final."
    }
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 2: Resolucion DNS del servidor ADO
# ----------------------------------------------------------------

Write-Host "---- TEST 2: Resolucion DNS ----" -ForegroundColor White

try {
    $uri = [System.Uri]$AdoBaseUrl
    $hostname = $uri.Host
    Write-Info "Hostname extraido: $hostname"
    $dns = [System.Net.Dns]::GetHostAddresses($hostname)
    $ips = $dns | ForEach-Object { $_.IPAddressToString }
    Write-Pass "DNS resuelve '$hostname' -> $($ips -join ', ')"
} catch {
    Write-Fail "No se pudo resolver DNS para '$hostname': $($_.Exception.Message)"
    Write-Diag "Verifica que estas conectado a la red corporativa o VPN."
    Write-Diag "Prueba manualmente: Resolve-DnsName $hostname"
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 3: Conectividad TCP al puerto HTTPS
# ----------------------------------------------------------------

Write-Host "---- TEST 3: Conectividad TCP (puerto HTTPS) ----" -ForegroundColor White

try {
    $uri = [System.Uri]$AdoBaseUrl
    $hostname = $uri.Host
    $port = if ($uri.Port -gt 0) { $uri.Port } else { 443 }
    Write-Info "Probando TCP $hostname`:$port ..."
    $tcp = New-Object System.Net.Sockets.TcpClient
    $connect = $tcp.BeginConnect($hostname, $port, $null, $null)
    $wait = $connect.AsyncWaitHandle.WaitOne(5000, $false)
    if ($wait -and $tcp.Connected) {
        $tcp.Close()
        Write-Pass "Puerto TCP $port alcanzable en '$hostname'."
    } else {
        $tcp.Close()
        Write-Fail "Timeout conectando a ${hostname}:${port}. El puerto puede estar bloqueado por firewall."
        Write-Diag "Verifica reglas de firewall o proxy corporativo."
    }
} catch {
    Write-Fail "Error TCP: $($_.Exception.Message)"
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 4: HTTP GET al endpoint raiz de la collection
# ----------------------------------------------------------------

Write-Host "---- TEST 4: HTTP GET al endpoint de la collection ----" -ForegroundColor White

$collectionUrl = "$AdoBaseUrl/_apis?api-version=5.0"
Write-Info "URL: $collectionUrl"

try {
    if ($PatToken) {
        $resp = Invoke-AdoApi -Url $collectionUrl -Pat $PatToken
    } else {
        $resp = Invoke-AdoApi -Url $collectionUrl -UseDefaultCredentials
    }
    Write-Pass "HTTP $($resp.StatusCode) - Collection accesible."
} catch [System.Net.WebException] {
    $httpCode = "desconocido"
    if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
    Write-Fail "HTTP $httpCode al llamar la collection."
    switch ($httpCode) {
        401 {
            Write-Diag "PAT invalido, vencido, o no tiene permisos basicos de lectura."
            Write-Diag "Verifica la fecha de expiracion del PAT en ADO: User Settings -> Personal Access Tokens."
            Write-Diag "Si el servidor usa HTTPS con certificado autofirmado, agrega el cert al store de Windows."
        }
        403 {
            Write-Diag "PAT valido pero sin acceso a esta collection."
            Write-Diag "Verifica que el PAT fue creado para la organization/collection correcta."
        }
        404 {
            Write-Diag "La URL de la collection no existe: $AdoBaseUrl"
            Write-Diag "Verifica la URL. Formato esperado: https://<servidor>/tfs/<NombreCollection>"
        }
        default {
            Write-Diag "Mensaje: $($_.Exception.Message)"
        }
    }
} catch {
    Write-Fail "Error inesperado: $($_.Exception.Message)"
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 5: Listar proyectos (Code Read minimo)
# ----------------------------------------------------------------

Write-Host "---- TEST 5: Listar proyectos de la collection ----" -ForegroundColor White

$projectsUrl = "$AdoBaseUrl/_apis/projects?`$top=5&api-version=5.0"
Write-Info "URL: $projectsUrl"

try {
    if ($PatToken) {
        $resp = Invoke-AdoApi -Url $projectsUrl -Pat $PatToken
    } else {
        $resp = Invoke-AdoApi -Url $projectsUrl -UseDefaultCredentials
    }
    $body = $resp.Content | ConvertFrom-Json
    $count = $body.count
    $names = ($body.value | Select-Object -First 5 | ForEach-Object { $_.name }) -join ", "
    Write-Pass "Se listaron $count proyecto(s). Primeros: $names"
} catch [System.Net.WebException] {
    $httpCode = "desconocido"
    if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
    Write-Fail "HTTP $httpCode al listar proyectos."
    if ($httpCode -eq 401) {
        Write-Diag "El PAT no tiene permiso 'Project and Team - Read' o esta vencido."
    } elseif ($httpCode -eq 403) {
        Write-Diag "El PAT no tiene acceso a esta collection."
    }
} catch {
    Write-Fail "Error: $($_.Exception.Message)"
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 6: Acceso al proyecto especifico
# ----------------------------------------------------------------

Write-Host "---- TEST 6: Acceso al proyecto '$Project' ----" -ForegroundColor White

$projectUrl = "$AdoBaseUrl/_apis/projects/$Project`?api-version=5.0"
Write-Info "URL: $projectUrl"

try {
    if ($PatToken) {
        $resp = Invoke-AdoApi -Url $projectUrl -Pat $PatToken
    } else {
        $resp = Invoke-AdoApi -Url $projectUrl -UseDefaultCredentials
    }
    $proj = $resp.Content | ConvertFrom-Json
    Write-Pass "Proyecto '$($proj.name)' encontrado (ID: $($proj.id), Estado: $($proj.state))."
} catch [System.Net.WebException] {
    $httpCode = "desconocido"
    if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
    Write-Fail "HTTP $httpCode al acceder al proyecto '$Project'."
    if ($httpCode -eq 404) {
        Write-Diag "El proyecto '$Project' no existe o el PAT no tiene acceso a el."
        Write-Diag "Verifica el nombre exacto del proyecto en ADO (distingue mayusculas/minusculas)."
    }
} catch {
    Write-Fail "Error: $($_.Exception.Message)"
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 7: Listar repos Git del proyecto
# ----------------------------------------------------------------

Write-Host "---- TEST 7: Listar repos Git en '$Project' ----" -ForegroundColor White

$reposUrl = "$AdoBaseUrl/$Project/_apis/git/repositories?api-version=5.0"
Write-Info "URL: $reposUrl"

try {
    if ($PatToken) {
        $resp = Invoke-AdoApi -Url $reposUrl -Pat $PatToken
    } else {
        $resp = Invoke-AdoApi -Url $reposUrl -UseDefaultCredentials
    }
    $body = $resp.Content | ConvertFrom-Json
    $count = $body.count
    Write-Pass "$count repo(s) Git encontrado(s) en '$Project'."
    $body.value | ForEach-Object {
        Write-Info "  Repo: $($_.name)  (remoteUrl: $($_.remoteUrl))"
    }
} catch [System.Net.WebException] {
    $httpCode = "desconocido"
    if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
    Write-Fail "HTTP $httpCode al listar repos Git."
    if ($httpCode -eq 401 -or $httpCode -eq 403) {
        Write-Diag "El PAT necesita el scope 'Code - Read' para listar repositorios Git."
    }
} catch {
    Write-Fail "Error: $($_.Exception.Message)"
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 8: Acceso al repo Git especifico via API
# ----------------------------------------------------------------

Write-Host "---- TEST 8: Acceso al repo Git '$GitRepo' via API ----" -ForegroundColor White

$repoUrl = "$AdoBaseUrl/$Project/_apis/git/repositories/$GitRepo`?api-version=5.0"
Write-Info "URL: $repoUrl"

try {
    if ($PatToken) {
        $resp = Invoke-AdoApi -Url $repoUrl -Pat $PatToken
    } else {
        $resp = Invoke-AdoApi -Url $repoUrl -UseDefaultCredentials
    }
    $repo = $resp.Content | ConvertFrom-Json
    Write-Pass "Repo '$($repo.name)' accesible via API."
    Write-Info "  Remote URL : $($repo.remoteUrl)"
    Write-Info "  Default branch: $($repo.defaultBranch)"
    Write-Info "  Size (KB)  : $([math]::Round($repo.size / 1KB, 1))"
} catch [System.Net.WebException] {
    $httpCode = "desconocido"
    if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
    Write-Fail "HTTP $httpCode al acceder al repo '$GitRepo'."
    if ($httpCode -eq 404) {
        Write-Diag "El repo '$GitRepo' no existe en el proyecto '$Project'."
        Write-Diag "Verifica el nombre exacto en ADO (URL: $AdoBaseUrl/$Project/_git)."
    }
} catch {
    Write-Fail "Error: $($_.Exception.Message)"
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 9: Clone superficial del repo Git (git ls-remote)
# ----------------------------------------------------------------

Write-Host "---- TEST 9: Autenticacion git (ls-remote) al repo '$GitRepo' ----" -ForegroundColor White

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Fail "git no esta instalado o no esta en el PATH."
    Write-Diag "Instala Git for Windows: https://git-scm.com/download/win"
} else {
    $gitVersion = & git --version 2>&1
    Write-Info "Git version: $gitVersion"

    $cloneUrl = "$AdoBaseUrl/$Project/_git/$GitRepo"
    if ($PatToken) {
        $authUrl = $cloneUrl -replace 'https://', "https://user:$PatToken@"
    } else {
        $authUrl = $cloneUrl
    }

    Write-Info "Ejecutando: git ls-remote $cloneUrl"
    $lsOutput = & git ls-remote $authUrl 2>&1
    $lsExit = $LASTEXITCODE

    if ($lsExit -eq 0) {
        $refCount = @($lsOutput | Where-Object { $_ -match "refs/" }).Count
        Write-Pass "git ls-remote exitoso. $refCount ref(s) encontradas."
        $lsOutput | Select-Object -First 5 | ForEach-Object { Write-Info "  $_" }
    } else {
        $outStr = $lsOutput -join " | "
        Write-Fail "git ls-remote fallo (exit code: $lsExit)."
        if ($outStr -match 'Authentication failed|403|401') {
            Write-Diag "Autenticacion fallida. El PAT puede ser incorrecto o no tener 'Code - Read'."
            Write-Diag "En ADO Server, el usuario para Basic Auth debe ser cualquier texto (no vacio)."
            Write-Diag "Formato correcto: https://cualquiercosa:<PAT>@<servidor>/tfs/<collection>/..."
        } elseif ($outStr -match 'unable to access|Could not resolve|Failed to connect|timed out') {
            Write-Diag "Sin acceso de red al servidor ADO."
            Write-Diag "Verifica VPN, DNS y que el servidor responde en HTTPS."
        } elseif ($outStr -match 'SSL|certificate') {
            Write-Diag "Error SSL/TLS. El servidor ADO puede usar un certificado autofirmado."
            Write-Diag "Opciones:"
            Write-Diag "  1. Instalar el certificado del servidor en el store de Windows."
            Write-Diag "  2. (Solo para pruebas): git config --global http.sslVerify false"
        } else {
            Write-Diag "Salida completa: $outStr"
        }
    }
}

Write-Host ""

# ----------------------------------------------------------------
# TEST 10: Acceso TFVC (items API)
# ----------------------------------------------------------------

Write-Host "---- TEST 10: Acceso TFVC en '$Project' ----" -ForegroundColor White

$tfvcUrl = "$AdoBaseUrl/$Project/_apis/tfvc/items?scopePath=`$/$Project&recursionLevel=OneLevel&api-version=5.0"
Write-Info "URL: $tfvcUrl"

try {
    if ($PatToken) {
        $resp = Invoke-AdoApi -Url $tfvcUrl -Pat $PatToken
    } else {
        $resp = Invoke-AdoApi -Url $tfvcUrl -UseDefaultCredentials
    }
    $body = $resp.Content | ConvertFrom-Json
    $itemCount = @($body.value).Count
    if ($itemCount -gt 0) {
        Write-Pass "TFVC accesible en '$Project'. $itemCount item(s) en root."
    } else {
        Write-Info "TFVC accesible pero sin items en '`$/$Project' (puede ser solo Git)."
    }
} catch [System.Net.WebException] {
    $httpCode = "desconocido"
    if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
    if ($httpCode -eq 404) {
        Write-Info "HTTP 404 - El proyecto '$Project' no tiene contenido TFVC (es normal si es solo Git)."
    } elseif ($httpCode -eq 401 -or $httpCode -eq 403) {
        Write-Fail "HTTP $httpCode - PAT sin permiso 'Code - Read' para TFVC."
    } else {
        Write-Fail "HTTP $httpCode al consultar TFVC."
        Write-Diag "Mensaje: $($_.Exception.Message)"
    }
} catch {
    Write-Fail "Error: $($_.Exception.Message)"
}

Write-Host ""

# ----------------------------------------------------------------
# RESUMEN
# ----------------------------------------------------------------

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  RESUMEN DIAGNOSTICO" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Tests pasados : $passed" -ForegroundColor Green
Write-Host "  Tests fallidos: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "================================================================" -ForegroundColor Cyan

if ($failed -eq 0) {
    Write-Host ""
    Write-Host "  Todos los tests pasaron. El PAT esta listo para la migracion." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  Resuelve los [FAIL] indicados antes de ejecutar test-migrate.ps1." -ForegroundColor Red
}
Write-Host ""
