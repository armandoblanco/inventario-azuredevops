# Requisitos de Red - VM de Migracion ADO Server a GitHub

## Contexto

Esta VM requiere conectividad simultanea a tres entornos:

- **Azure DevOps Server OnPrem** (source): `https://bcrtfs/tfs/BCRCollection`
- **Azure DevOps Services Cloud** (Boards, Pipelines, Artifacts): `https://dev.azure.com/{org}`
- **GitHub Enterprise Cloud** (repos): `https://github.com`

Toda la comunicacion es **outbound** desde la VM. No se requieren reglas inbound salvo que se configure el agente como listener (no recomendado).

---

## 1. Azure DevOps Server OnPrem

Conectividad interna. No requiere reglas de firewall externo.

| Endpoint | Puerto | Protocolo | Uso |
|----------|--------|-----------|-----|
| `bcrtfs` (o IP del servidor TFS) | 443 | HTTPS | API REST, git clone --mirror |
| `bcrtfs` (o IP del servidor TFS) | 8080 | HTTP | Alternativo si TFS no usa HTTPS |
| SQL Server del TFS | 1433 | TCP | Solo si se ejecuta Data Migration Tool desde esta VM |

**Nota:** Si el certificado TLS del servidor TFS es self-signed, git requiere configuracion adicional: `git config --global http.sslVerify false` o agregar el CA al trust store de la VM.

---

## 2. Azure DevOps Services (Cloud)

Referencia oficial: https://learn.microsoft.com/en-us/azure/devops/organizations/security/allow-list-ip-url

### Dominios (outbound, puerto 443)

| Dominio | Uso |
|---------|-----|
| `dev.azure.com` | Portal principal y API REST |
| `*.dev.azure.com` | Subdominios por organizacion |
| `{org}.visualstudio.com` | Legacy URL (todavia en uso) |
| `*.visualstudio.com` | Incluye vstmr, vsrm, vssps |
| `vsrm.dev.azure.com` | Release management |
| `feeds.dev.azure.com` | Artifacts feeds (NuGet, Maven, npm) |
| `pkgs.dev.azure.com` | Package downloads |
| `vssps.dev.azure.com` | Identity y authentication services |
| `vstsagentpackage.azureedge.net` | Descarga del agente self-hosted |
| `*.blob.core.windows.net` | Artifacts storage, pipeline logs, attachments |
| `*.vstmr.visualstudio.com` | Test management services |

### Puerto SSH (opcional)

| Dominio | Puerto | Uso |
|---------|--------|-----|
| `ssh.dev.azure.com` | 22 | Git operations via SSH |
| `vs-ssh.visualstudio.com` | 22 | Git SSH (legacy domain) |

### Rangos IP outbound

Si el firewall trabaja por IP en vez de por dominio:

**IPv4:**

```
13.107.6.0/24
13.107.9.0/24
13.107.42.0/24
13.107.43.0/24
150.171.22.0/24
150.171.23.0/24
150.171.73.0/24
150.171.74.0/24
150.171.75.0/24
150.171.76.0/24
```

**IPv6:**

```
2620:1ec:4::/48
2620:1ec:a92::/48
2620:1ec:21::/48
2620:1ec:22::/48
2620:1ec:50::/48
2620:1ec:51::/48
2603:1061:10::/48
```

**Importante:** Estos rangos cambian periodicamente. Consultar siempre la documentacion oficial.

---

## 3. GitHub (Cloud)

Referencia oficial: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-githubs-ip-addresses

### Dominios (outbound, puerto 443)

| Dominio | Uso |
|---------|-----|
| `github.com` | Web portal, API REST, git push/pull HTTPS |
| `*.github.com` | Subservicios varios |
| `api.github.com` | API REST (GEI, gh CLI, GitHub Apps) |
| `*.githubusercontent.com` | Raw content, avatars, release assets |
| `objects.githubusercontent.com` | Git LFS objects |
| `github-releases.githubusercontent.com` | Release downloads, gh CLI binaries |
| `*.githubassets.com` | Static assets del portal web |
| `uploads.github.com` | Upload de releases y artifacts |
| `ghcr.io` | GitHub Container Registry (si se usa) |
| `*.actions.githubusercontent.com` | GitHub Actions runners (si se usa) |
| `codeload.github.com` | Download de archives (ZIP/TAR) |

### Puerto SSH (opcional)

| Dominio | Puerto | Uso |
|---------|--------|-----|
| `github.com` | 22 | Git operations via SSH |

### Rangos IP dinamicos

Los rangos de IP de GitHub cambian frecuentemente. Consultar programaticamente:

```bash
curl -s https://api.github.com/meta
```

Retorna un JSON con rangos para `web`, `api`, `git`, `packages`, `actions`, etc.

---

## 4. Autenticacion (Microsoft Entra ID)

Requerido para autenticacion contra Azure DevOps Cloud y para Data Migration Tool.

| Dominio | Puerto | Uso |
|---------|--------|-----|
| `login.microsoftonline.com` | 443 | Entra ID (OAuth, SAML) |
| `login.live.com` | 443 | Microsoft account fallback |
| `aadcdn.msauth.net` | 443 | Entra ID auth libraries |
| `login.windows.net` | 443 | Legacy Azure AD endpoint |
| `secure.aadcdn.microsoftonline-p.com` | 443 | Entra ID CDN |

---

## 5. NuGet / Package Feeds (si las pipelines restauran paquetes)

| Dominio | Puerto | Uso |
|---------|--------|-----|
| `api.nuget.org` | 443 | NuGet.org public feed |
| `*.nuget.org` | 443 | NuGet services |
| `feeds.dev.azure.com` | 443 | Azure Artifacts NuGet feed (ya listado arriba) |
| `repo.maven.apache.org` | 443 | Maven Central (para TPSistar Java) |
| `*.maven.org` | 443 | Maven repositories |

---

## 6. Herramientas de migracion (temporales)

Solo necesarios durante la ejecucion de la migracion. Pueden cerrarse despues.

| Dominio | Puerto | Uso |
|---------|--------|-----|
| `cli.github.com` | 443 | Instalacion de gh CLI |
| `github.com/github/gh-gei` | 443 | Descarga de GitHub Enterprise Importer |
| `github.com/git-tfs/git-tfs` | 443 | git-tfs (si se migra TFVC con historial) |
| `chocolatey.org` | 443 | Chocolatey package manager (opcional) |
| `pypi.org` | 443 | gitleaks, trufflehog (scan de secrets) |
| `files.pythonhosted.org` | 443 | Python package downloads |
| `registry.npmjs.org` | 443 | gh-migration-analyzer (si se usa) |

---

## 7. Resumen de puertos

| Puerto | Protocolo | Direccion | Uso |
|--------|-----------|-----------|-----|
| 443 | HTTPS | Outbound | Todo: ADO Cloud, GitHub, Entra ID, APIs |
| 22 | SSH | Outbound | Git SSH (opcional, solo si no se usa HTTPS) |
| 8080 | HTTP | Internal | TFS OnPrem (si no usa HTTPS) |
| 1433 | TCP | Internal | SQL Server TFS (solo para DMT) |

---

## 8. Requisitos adicionales de la VM

| Requisito | Detalle |
|-----------|---------|
| OS | Windows Server 2019+ o Windows 10/11 |
| PowerShell | 5.1 (incluido) o 7.x |
| Git | 2.25+ (git-for-windows) |
| gh CLI | Ultima version (para GEI) |
| .NET | 4.6.2+ (para git-tfs si se usa) |
| Team Explorer | 2017 o 2019 (solo si se usa git-tfs) |
| Disco | Minimo 50 GB libres para mirror clones (TPSistar = 721 MB, mas temporales) |
| RAM | Minimo 8 GB |
| Proxy | Si hay proxy corporativo, configurar en git, gh CLI, y PowerShell |

### Configuracion de proxy (si aplica)

```powershell
# Git
git config --global http.proxy http://proxy.corp:8080
git config --global https.proxy http://proxy.corp:8080

# PowerShell
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy("http://proxy.corp:8080")
[System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials

# gh CLI
$env:HTTPS_PROXY = "http://proxy.corp:8080"
```

---

## 9. Script de validacion de conectividad

Ejecutar desde la VM antes de iniciar cualquier trabajo de migracion. Cada linea FAIL es un request de firewall pendiente.

```powershell
$endpoints = @(
    @{ Name = "ADO Server OnPrem";     Url = "https://bcrtfs/tfs/BCRCollection"; Port = 443 },
    @{ Name = "ADO Cloud Portal";      Url = "https://dev.azure.com"; Port = 443 },
    @{ Name = "ADO Cloud Identity";    Url = "https://vssps.dev.azure.com"; Port = 443 },
    @{ Name = "ADO Cloud Feeds";       Url = "https://feeds.dev.azure.com"; Port = 443 },
    @{ Name = "ADO Cloud Packages";    Url = "https://pkgs.dev.azure.com"; Port = 443 },
    @{ Name = "ADO Cloud VSRM";        Url = "https://vsrm.dev.azure.com"; Port = 443 },
    @{ Name = "ADO Agent Download";    Url = "https://vstsagentpackage.azureedge.net"; Port = 443 },
    @{ Name = "GitHub Web";            Url = "https://github.com"; Port = 443 },
    @{ Name = "GitHub API";            Url = "https://api.github.com"; Port = 443 },
    @{ Name = "GitHub Content";        Url = "https://objects.githubusercontent.com"; Port = 443 },
    @{ Name = "GitHub Releases";       Url = "https://github-releases.githubusercontent.com"; Port = 443 },
    @{ Name = "GitHub CLI";            Url = "https://cli.github.com"; Port = 443 },
    @{ Name = "GitHub SSH";            Url = "github.com"; Port = 22 },
    @{ Name = "Entra ID";              Url = "https://login.microsoftonline.com"; Port = 443 },
    @{ Name = "Microsoft Auth";        Url = "https://login.live.com"; Port = 443 },
    @{ Name = "NuGet.org";             Url = "https://api.nuget.org"; Port = 443 },
    @{ Name = "Azure Blob Storage";    Url = "https://vsblob.dev.azure.com"; Port = 443 }
)

Write-Host ""
Write-Host "=== Validacion de Conectividad - VM de Migracion ===" -ForegroundColor Cyan
Write-Host "Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "Host:  $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host ""

$results = @()

foreach ($ep in $endpoints) {
    $name = $ep.Name
    $port = $ep.Port
    $status = "UNKNOWN"
    $detail = ""

    if ($ep.Url -match '^https?://') {
        try {
            $response = Invoke-WebRequest -Uri $ep.Url -Method Head -TimeoutSec 10 -UseBasicParsing
            $status = "OK"
            $detail = "HTTP $($response.StatusCode)"
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match '401|403|404|405|301|302|308') {
                $status = "OK"
                $detail = "Reachable (auth/redirect expected)"
            }
            else {
                $status = "FAIL"
                $detail = $msg.Substring(0, [Math]::Min(80, $msg.Length))
            }
        }
    }
    else {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect($ep.Url, $port)
            $tcp.Close()
            $status = "OK"
            $detail = "TCP port $port open"
        }
        catch {
            $status = "FAIL"
            $detail = "Port $port closed or blocked"
        }
    }

    $color = "Green"
    if ($status -eq "FAIL") { $color = "Red" }

    $displayUrl = $ep.Url
    if ($port -ne 443) { $displayUrl = "$($ep.Url):$port" }

    Write-Host "  [$status]  $($name.PadRight(25)) $displayUrl" -ForegroundColor $color
    if ($status -eq "FAIL") {
        Write-Host "           $detail" -ForegroundColor DarkRed
    }

    $results += [PSCustomObject]@{
        Endpoint = $name
        Url      = $ep.Url
        Port     = $port
        Status   = $status
        Detail   = $detail
    }
}

# Resumen
$okCount = @($results | Where-Object { $_.Status -eq "OK" }).Count
$failCount = @($results | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host ""
Write-Host "=== Resumen ===" -ForegroundColor Cyan
Write-Host "  OK:   $okCount" -ForegroundColor Green
Write-Host "  FAIL: $failCount" -ForegroundColor Red
Write-Host ""

if ($failCount -gt 0) {
    Write-Host "Endpoints que requieren apertura de firewall:" -ForegroundColor Yellow
    $results | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        Write-Host "  - $($_.Endpoint): $($_.Url) puerto $($_.Port)" -ForegroundColor Yellow
    }
}

# Exportar a CSV
$csvPath = ".\connectivity_test_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "Resultados exportados a: $csvPath" -ForegroundColor Cyan
```

---

## 10. Consideraciones de seguridad

- **TLS 1.2 minimo:** Tanto Azure DevOps Cloud como GitHub requieren TLS 1.2+. Si la VM tiene TLS 1.0/1.1 habilitado por default (Windows Server 2012 R2 o anterior), deshabilitar versiones antiguas.
- **SNI (Server Name Indication):** Azure DevOps Cloud requiere SNI en todas las conexiones HTTPS desde abril 2025. Verificar que el proxy corporativo no haga TLS termination sin SNI.
- **Inspeccion TLS (break and inspect):** Si el firewall corporativo hace inspeccion TLS, git y gh CLI van a fallar con errores de certificado. Opciones: excluir los dominios de GitHub y ADO Cloud de la inspeccion, o inyectar el CA del firewall en los trust stores de git, PowerShell, y gh CLI.
- **No almacenar PATs en scripts:** Usar variables de entorno (`$env:ADO_PAT`, `$env:GH_PAT`) y limpiar despues de cada sesion.

---

## Referencias

- Azure DevOps allowed IPs and URLs: https://learn.microsoft.com/en-us/azure/devops/organizations/security/allow-list-ip-url
- GitHub IP addresses (meta API): https://api.github.com/meta
- GitHub Copilot allowlist: https://docs.github.com/en/copilot/reference/copilot-allowlist-reference
- ADO IP update (Feb 2025): https://devblogs.microsoft.com/devops/update-to-ado-allowed-ip-addresses/
- SNI requirement (Apr 2025): https://devblogs.microsoft.com/devops/sni-mandatory-for-azdo-services/
