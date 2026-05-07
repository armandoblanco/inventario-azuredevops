<#
.SYNOPSIS
    Migrate-ProjectUsers.ps1
    Migra usuarios y Teams de un Team Project en Azure DevOps Server OnPrem
    hacia Azure DevOps Services (Cloud).

.DESCRIPTION
    Automatiza la migracion de usuarios y equipos en DOS pasos:

    PASO 1 - Inventario (sin -Execute):
      Recolecta todos los Teams y sus miembros del proyecto origen y genera
      un CSV editable (users-manifest.csv) para que el usuario complete:
        - TargetEmail   : email/UPN del usuario en Azure AD
        - AccessLevel   : stakeholder | express | advanced
        - GroupType      : projectReader | projectContributor | projectAdministrator
      Tambien genera un reporte JSON con la estructura completa.

    PASO 2 - Ejecucion (con -Execute y -ManifestFile):
      Lee el CSV completado y ejecuta:
        Fase 1: Alta de usuarios en la organizacion destino (User Entitlements API)
        Fase 2: Creacion de Teams en el proyecto destino (Teams API)
        Fase 3: Asignacion de miembros a Teams (Graph Memberships API)

    REQUISITOS:
      - El Team Project destino debe existir.
      - Los usuarios destino deben existir en Azure AD (Entra ID).
      - El PAT de destino necesita scopes:
          Member Entitlement Management (Read & Write)
          Graph (Read & Manage)
          Project and Team (Read, Write & Manage)

    LIMITACIONES:
      - No migra permisos granulares (TFVC, Git, Build, etc.), solo grupo de proyecto.
      - Los grupos de seguridad custom (no Teams) no se recrean automaticamente.
      - Si un usuario no existe en Azure AD, el alta via Entitlements fallara.

.PARAMETER SourceBaseUrl
    URL base de la collection origen (ADO Server). Lee $env:ADO_SOURCE_BASE.

.PARAMETER SourcePat
    PAT del ADO Server origen. Lee $env:ADO_SOURCE_PAT.

.PARAMETER SourceProject
    Nombre del Team Project origen.

.PARAMETER TargetOrgUrl
    URL de la org destino (ej. https://dev.azure.com/MiOrg). Lee $env:ADO_TARGET_ORG_URL.

.PARAMETER TargetPat
    PAT de ADO Services destino. Lee $env:ADO_TARGET_PAT.

.PARAMETER TargetProject
    Nombre del Team Project destino. Lee $env:ADO_TARGET_PROJECT.

.PARAMETER ManifestFile
    Ruta al CSV de mapeo completado por el usuario (users-manifest.csv).
    Si no se provee, el script solo genera el template de inventario.

.PARAMETER DefaultAccessLevel
    Nivel de acceso por defecto para el CSV template: stakeholder, express (Basic),
    advanced (VS Enterprise). Default: express.

.PARAMETER DefaultGroupType
    Grupo de proyecto por defecto: projectReader, projectContributor,
    projectAdministrator. Default: projectContributor.

.PARAMETER OutputDir
    Directorio de salida. Default: .\users-migration

.PARAMETER SkipTeamCreation
    Si se activa, no crea Teams en destino (solo alta de usuarios).

.PARAMETER SkipMemberships
    Si se activa, no asigna miembros a Teams.

.PARAMETER Execute
    Switch para ejecutar cambios reales. Sin este flag, solo modo inventario/dry-run.

.PARAMETER EnvFile
    Ruta al archivo .env. Default: ../.env (un nivel arriba del script).

.EXAMPLE
    # PASO 1: Generar inventario y CSV template
    .\Migrate-ProjectUsers.ps1 -SourceProject "TPBCRSICCRED" -TargetProject "Prueba"

.EXAMPLE
    # PASO 2: Ejecutar migracion con CSV completado
    .\Migrate-ProjectUsers.ps1 -SourceProject "TPBCRSICCRED" -TargetProject "Prueba" `
        -ManifestFile ".\users-migration\users-manifest.csv" -Execute
#>

[CmdletBinding()]
param(
    [string]$SourceBaseUrl,
    [string]$SourcePat,
    [Parameter(Mandatory=$true)]
    [string]$SourceProject,
    [string]$TargetOrgUrl,
    [string]$TargetPat,
    [string]$TargetProject,
    [string]$ManifestFile,
    [string]$DefaultAccessLevel = "express",
    [string]$DefaultGroupType   = "projectContributor",
    [string]$OutputDir = ".\users-migration",
    [string]$SourceApiVersion = "5.0",
    [string]$TargetApiVersion = "7.1",
    [switch]$SkipTeamCreation,
    [switch]$SkipMemberships,
    [switch]$Execute,
    [string]$EnvFile = (Join-Path (Split-Path $PSScriptRoot -Parent) ".env")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ================================================================
# HELPERS
# ================================================================
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

if (-not $SourceBaseUrl)  { $SourceBaseUrl  = $env:ADO_SOURCE_BASE  }
if (-not $SourcePat)      { $SourcePat      = $env:ADO_SOURCE_PAT   }
if (-not $TargetOrgUrl)   { $TargetOrgUrl   = $env:ADO_TARGET_ORG_URL }
if (-not $TargetPat)      { $TargetPat      = $env:ADO_TARGET_PAT   }
if (-not $TargetProject)  { $TargetProject  = $env:ADO_TARGET_PROJECT }

if (-not $SourceBaseUrl) { $SourceBaseUrl = $env:ADO_BASE }
if (-not $SourcePat)     { $SourcePat     = $env:ADO_PAT  }

if (-not $SourceBaseUrl) { Write-Host "ERROR: Falta SourceBaseUrl (ADO_SOURCE_BASE)." -ForegroundColor Red; exit 1 }
if (-not $TargetOrgUrl)  { Write-Host "ERROR: Falta TargetOrgUrl (ADO_TARGET_ORG_URL)." -ForegroundColor Red; exit 1 }
if (-not $TargetProject) { Write-Host "ERROR: Falta TargetProject (ADO_TARGET_PROJECT)." -ForegroundColor Red; exit 1 }
if (-not $TargetPat)     { Write-Host "ERROR: Falta TargetPat (ADO_TARGET_PAT)." -ForegroundColor Red; exit 1 }
if (-not $SourcePat)     { Write-Host "WARN: ADO_SOURCE_PAT vacio, usando credenciales Windows." -ForegroundColor Yellow }

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Derivar URLs de servicios auxiliares del destino
$TargetOrgUrl = $TargetOrgUrl.TrimEnd('/')
$orgName  = ($TargetOrgUrl -split '/')[-1]
$vsaexUrl = "https://vsaex.dev.azure.com/$orgName"
$vsspsUrl = "https://vssps.dev.azure.com/$orgName"

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "DRY"   { "DarkCyan" }
        default { "Gray" }
    }
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Pretty-Action {
    param([string]$Action, [string]$Detail)
    $prefix = if ($Execute) { "[EXEC]" } else { "[DRY-RUN]" }
    $color  = if ($Execute) { "Green" } else { "DarkCyan" }
    Write-Host "  $prefix $Action : $Detail" -ForegroundColor $color
}

# ================================================================
# REST helpers
# ================================================================
function Invoke-Ado {
    param([string]$Url, [string]$Method = "GET", $Body, [string]$ContentType = "application/json")
    $SourceBaseUrl = $SourceBaseUrl  # closure
    $headers = @{}
    $params = @{ Uri = $Url; Method = $Method; ContentType = $ContentType; UseBasicParsing = $true }
    if ($SourcePat) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$SourcePat"))
        $headers["Authorization"] = "Basic $b64"
    } else {
        $params["UseDefaultCredentials"] = $true
    }
    $params["Headers"] = $headers
    if ($Body) { $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 } }
    try { return (Invoke-RestMethod @params) }
    catch {
        $msg = $_.Exception.Message
        try { $msg = ($_ | ConvertFrom-Json).message } catch {}
        return [PSCustomObject]@{ _error = $true; _message = $msg; _status = $_.Exception.Response.StatusCode }
    }
}

function Invoke-Target {
    param([string]$BaseUrl, [string]$Path, [string]$Method = "GET", $Body,
          [string]$ContentType = "application/json", [string]$ApiVer = $TargetApiVersion)
    $sep = if ($Path.Contains("?")) { "&" } else { "?" }
    $url = "$BaseUrl/$Path${sep}api-version=$ApiVer"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$TargetPat"))
    $headers = @{ "Authorization" = "Basic $b64" }
    $params = @{ Uri = $url; Method = $Method; Headers = $headers; ContentType = $ContentType; UseBasicParsing = $true }
    if ($Body) { $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 } }
    try { return (Invoke-RestMethod @params) }
    catch {
        $msg = $_.Exception.Message
        try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json); $msg = $detail.message } catch {}
        return [PSCustomObject]@{ _error = $true; _message = $msg; _status = $_.Exception.Response.StatusCode }
    }
}

function Test-IsErr { param($r) if ($null -eq $r) { return $true }; if ($r.PSObject.Properties.Match('_error').Count -gt 0) { return [bool]$r._error }; return $false }
function Get-ErrMsg { param($r) if ($null -eq $r) { return "null" }; if ($r.PSObject.Properties.Match('_message').Count -gt 0) { return $r._message }; return "unknown" }

function Load-Map {
    param([string]$Path)
    $map = @{}
    if (Test-Path $Path) {
        $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
    return $map
}
function Save-Map { param([hashtable]$Map, [string]$Path) ($Map | ConvertTo-Json -Depth 5) | Out-File -FilePath $Path -Encoding UTF8 }

# ================================================================
# Phase 1: Inventory source teams + members
# ================================================================
function Get-SourceTeamsInventory {
    Write-Status "=== FASE 1: Inventario de Teams y Miembros (origen) ===" -Level OK

    $url = "$SourceBaseUrl/_apis/projects/$SourceProject/teams?`$top=500&api-version=$SourceApiVersion"
    $teamsResp = Invoke-Ado -Url $url
    if (Test-IsErr $teamsResp) {
        Write-Status "ERROR obteniendo teams: $(Get-ErrMsg $teamsResp)" -Level ERROR
        return $null
    }

    $teams = @()
    if ($teamsResp.PSObject.Properties.Match('value').Count -gt 0) { $teams = $teamsResp.value }
    Write-Status "Teams encontrados en origen: $($teams.Count)" -Level OK

    $inventory = @()
    $userIndex = @{}

    foreach ($team in $teams) {
        $teamName = $team.name
        $teamDesc = if ($team.PSObject.Properties.Match('description').Count -gt 0) { $team.description } else { "" }

        $membersUrl = "$SourceBaseUrl/_apis/projects/$SourceProject/teams/$($team.id)/members?`$top=500&api-version=$SourceApiVersion"
        $membersResp = Invoke-Ado -Url $membersUrl
        if (Test-IsErr $membersResp) {
            Write-Status "  WARN: No se pudieron obtener miembros de '$teamName': $(Get-ErrMsg $membersResp)" -Level WARN
            continue
        }

        $members = @()
        if ($membersResp.PSObject.Properties.Match('value').Count -gt 0) { $members = $membersResp.value }
        Write-Status "  Team '$teamName': $($members.Count) miembros" -Level INFO

        foreach ($m in $members) {
            $identity = $m.identity
            $uniqueName  = if ($identity.PSObject.Properties.Match('uniqueName').Count -gt 0) { $identity.uniqueName } else { "" }
            $displayName = if ($identity.PSObject.Properties.Match('displayName').Count -gt 0) { $identity.displayName } else { "" }
            $email       = ""
            # Intentar extraer email del uniqueName si tiene formato email
            if ($uniqueName -match '@') { $email = $uniqueName }

            $key = if ($uniqueName) { $uniqueName } else { $displayName }
            if (-not $key) { continue }

            if (-not $userIndex.ContainsKey($key)) {
                $userIndex[$key] = [PSCustomObject]@{
                    SourceUniqueName  = $uniqueName
                    SourceDisplayName = $displayName
                    SourceEmail       = $email
                    TargetEmail       = $email  # pre-llenar si tiene formato email
                    AccessLevel       = $DefaultAccessLevel
                    GroupType         = $DefaultGroupType
                    Teams             = $teamName
                    SourceId          = $identity.id
                }
            } else {
                # Agregar team adicional
                $existing = $userIndex[$key]
                $existingTeams = $existing.Teams -split ";"
                if ($existingTeams -notcontains $teamName) {
                    $existing.Teams = $existing.Teams + ";$teamName"
                }
            }
        }
    }

    $inventory = @($userIndex.Values)
    Write-Status "Usuarios unicos encontrados: $($inventory.Count)" -Level OK
    return [PSCustomObject]@{ Teams = $teams; Users = $inventory }
}

# ================================================================
# Phase 2: User Entitlements (alta de usuarios en destino)
# ================================================================
function Get-TargetProjectId {
    $r = Invoke-Target -BaseUrl $TargetOrgUrl -Path "_apis/projects/$TargetProject"
    if (Test-IsErr $r) { Write-Status "ERROR obteniendo proyecto destino: $(Get-ErrMsg $r)" -Level ERROR; return $null }
    return $r.id
}

function Test-UserExists {
    param([string]$Email)
    $filter = "name eq '$Email'"
    $r = Invoke-Target -BaseUrl $vsaexUrl -Path "_apis/userentitlements?`$filter=$filter" -ApiVer "7.1-preview.4"
    if (Test-IsErr $r) { return $null }
    if ($r.PSObject.Properties.Match('members').Count -gt 0 -and $r.members.Count -gt 0) {
        return $r.members[0]
    }
    if ($r.PSObject.Properties.Match('value').Count -gt 0 -and $r.value.Count -gt 0) {
        return $r.value[0]
    }
    return $null
}

function Add-UserEntitlement {
    param([string]$Email, [string]$AccessLevel, [string]$GroupType, [string]$ProjectId)
    $body = @{
        accessLevel = @{ accountLicenseType = $AccessLevel }
        user = @{ principalName = $Email; subjectKind = "user" }
        projectEntitlements = @(
            @{
                group      = @{ groupType = $GroupType }
                projectRef = @{ id = $ProjectId }
            }
        )
    }
    return Invoke-Target -BaseUrl $vsaexUrl -Path "_apis/userentitlements" -Method POST -Body $body -ApiVer "7.1-preview.4"
}

function Provision-Users {
    param($Manifest, [string]$ProjectId)
    Write-Status "=== FASE 2: Alta de Usuarios en Destino ===" -Level OK

    $script:UserDescriptorMap = @{}
    $mapPath = Join-Path $OutputDir "mapping-users.json"
    $script:UserDescriptorMap = Load-Map $mapPath
    $added = 0; $skipped = 0; $errors = 0

    foreach ($row in $Manifest) {
        $email = $row.TargetEmail
        if ([string]::IsNullOrWhiteSpace($email)) {
            Write-Status "  SKIP: '$($row.SourceUniqueName)' sin TargetEmail" -Level WARN
            $skipped++
            continue
        }

        # Ya procesado
        if ($script:UserDescriptorMap.ContainsKey($email)) {
            Write-Status "  SKIP: '$email' ya procesado anteriormente" -Level INFO
            $skipped++
            continue
        }

        # Verificar si ya existe en la org
        $existing = Test-UserExists -Email $email
        if ($existing) {
            $desc = if ($existing.user -and $existing.user.descriptor) { $existing.user.descriptor } else { "unknown" }
            $uid  = if ($existing.id) { "$($existing.id)" } else { "unknown" }
            $script:UserDescriptorMap[$email] = @{ descriptor = $desc; id = $uid }
            Save-Map $script:UserDescriptorMap $mapPath
            Write-Status "  EXISTS: '$email' ya en la org (id=$uid)" -Level INFO
            $skipped++
            continue
        }

        $accessLevel = if ($row.AccessLevel) { $row.AccessLevel } else { $DefaultAccessLevel }
        $groupType   = if ($row.GroupType)    { $row.GroupType }    else { $DefaultGroupType }

        Pretty-Action "Alta Usuario" "'$email' acceso=$accessLevel grupo=$groupType"
        if ($Execute) {
            $r = Add-UserEntitlement -Email $email -AccessLevel $accessLevel -GroupType $groupType -ProjectId $ProjectId
            if (Test-IsErr $r) {
                Write-Status "    ERROR: $(Get-ErrMsg $r)" -Level ERROR
                $errors++
                continue
            }
            # Extraer descriptor del response
            $ue = if ($r.PSObject.Properties.Match('userEntitlement').Count -gt 0) { $r.userEntitlement }
                  elseif ($r.PSObject.Properties.Match('operationResult').Count -gt 0) { $r }
                  else { $r }
            $desc = "pending"
            $uid  = "pending"
            if ($ue.PSObject.Properties.Match('user').Count -gt 0 -and $ue.user.PSObject.Properties.Match('descriptor').Count -gt 0) {
                $desc = $ue.user.descriptor
            }
            if ($ue.PSObject.Properties.Match('id').Count -gt 0) { $uid = "$($ue.id)" }
            $script:UserDescriptorMap[$email] = @{ descriptor = $desc; id = $uid }
            Save-Map $script:UserDescriptorMap $mapPath
            Write-Status "    OK: '$email' agregado (id=$uid)" -Level OK
            $added++
        }
    }

    Write-Status "Usuarios: $added agregados, $skipped omitidos, $errors errores" -Level OK
}

# ================================================================
# Phase 3: Create Teams in target
# ================================================================
function Get-TargetTeams {
    $r = Invoke-Target -BaseUrl $TargetOrgUrl -Path "_apis/projects/$TargetProject/teams?`$top=500"
    if (Test-IsErr $r) { return @() }
    if ($r.PSObject.Properties.Match('value').Count -gt 0) { return $r.value }
    return @()
}

function Create-TargetTeams {
    param($SourceTeams)
    Write-Status "=== FASE 3: Crear Teams en Destino ===" -Level OK

    if ($SkipTeamCreation) {
        Write-Status "  Omitido por -SkipTeamCreation" -Level WARN
        return
    }

    $script:TeamMap = @{}
    $mapPath = Join-Path $OutputDir "mapping-teams.json"
    $script:TeamMap = Load-Map $mapPath

    # Obtener teams existentes en destino
    $existingTeams = Get-TargetTeams
    $existingNames = @{}
    foreach ($t in $existingTeams) { $existingNames[$t.name] = $t.id }

    $created = 0; $skipped = 0

    foreach ($team in $SourceTeams) {
        $teamName = $team.name
        $teamDesc = if ($team.PSObject.Properties.Match('description').Count -gt 0) { $team.description } else { "" }

        if ($script:TeamMap.ContainsKey($teamName)) {
            Write-Status "  SKIP: Team '$teamName' ya mapeado" -Level INFO
            $skipped++
            continue
        }

        if ($existingNames.ContainsKey($teamName)) {
            $script:TeamMap[$teamName] = "$($existingNames[$teamName])"
            Save-Map $script:TeamMap $mapPath
            Write-Status "  EXISTS: Team '$teamName' ya existe en destino (id=$($existingNames[$teamName]))" -Level INFO
            $skipped++
            continue
        }

        Pretty-Action "Crear Team" "'$teamName'"
        if ($Execute) {
            $body = @{ name = $teamName; description = $teamDesc }
            $r = Invoke-Target -BaseUrl $TargetOrgUrl -Path "_apis/projects/$TargetProject/teams" -Method POST -Body $body
            if (Test-IsErr $r) {
                Write-Status "    ERROR: $(Get-ErrMsg $r)" -Level ERROR
                continue
            }
            $script:TeamMap[$teamName] = "$($r.id)"
            Save-Map $script:TeamMap $mapPath
            Write-Status "    OK: Team '$teamName' creado (id=$($r.id))" -Level OK
            $created++
        }
    }

    Write-Status "Teams: $created creados, $skipped omitidos" -Level OK
}

# ================================================================
# Phase 4: Team Memberships via Graph API
# ================================================================
function Get-ProjectScopeDescriptor {
    param([string]$ProjectId)
    $r = Invoke-Target -BaseUrl $vsspsUrl -Path "_apis/graph/descriptors/$ProjectId" -ApiVer "7.1-preview.1"
    if (Test-IsErr $r) { return $null }
    return $r.value
}

function Get-GraphGroups {
    param([string]$ScopeDescriptor)
    $r = Invoke-Target -BaseUrl $vsspsUrl -Path "_apis/graph/groups?scopeDescriptor=$ScopeDescriptor" -ApiVer "7.1-preview.1"
    if (Test-IsErr $r) { return @() }
    if ($r.PSObject.Properties.Match('value').Count -gt 0) { return $r.value }
    return @()
}

function Get-UserDescriptor {
    param([string]$Email)
    if ($script:UserDescriptorMap.ContainsKey($Email)) {
        $entry = $script:UserDescriptorMap[$Email]
        if ($entry.descriptor -and $entry.descriptor -ne "pending" -and $entry.descriptor -ne "unknown") {
            return $entry.descriptor
        }
    }
    # Buscar en entitlements
    $existing = Test-UserExists -Email $Email
    if ($existing -and $existing.user -and $existing.user.descriptor) {
        return $existing.user.descriptor
    }
    return $null
}

function Add-GraphMembership {
    param([string]$MemberDescriptor, [string]$ContainerDescriptor)
    return Invoke-Target -BaseUrl $vsspsUrl -Path "_apis/graph/memberships/$MemberDescriptor/$ContainerDescriptor" -Method PUT -ApiVer "7.1-preview.1"
}

function Assign-TeamMemberships {
    param($Manifest, [string]$ProjectId)
    Write-Status "=== FASE 4: Asignar Miembros a Teams ===" -Level OK

    if ($SkipMemberships) {
        Write-Status "  Omitido por -SkipMemberships" -Level WARN
        return
    }

    # Obtener scope descriptor del proyecto
    $scopeDesc = Get-ProjectScopeDescriptor -ProjectId $ProjectId
    if (-not $scopeDesc) {
        Write-Status "ERROR: No se pudo obtener scope descriptor del proyecto" -Level ERROR
        return
    }

    # Obtener todos los grupos/teams del proyecto con sus descriptors
    $graphGroups = Get-GraphGroups -ScopeDescriptor $scopeDesc
    $teamDescriptors = @{}
    foreach ($g in $graphGroups) {
        $teamDescriptors[$g.displayName] = $g.descriptor
    }

    $assigned = 0; $skipped = 0; $errors = 0

    foreach ($row in $Manifest) {
        $email = $row.TargetEmail
        if ([string]::IsNullOrWhiteSpace($email)) { continue }

        $teams = @($row.Teams -split ";") | Where-Object { $_ -ne "" }
        if ($teams.Count -eq 0) { continue }

        $userDesc = Get-UserDescriptor -Email $email
        if (-not $userDesc) {
            Write-Status "  WARN: No se encontro descriptor para '$email', omitiendo memberships" -Level WARN
            $skipped++
            continue
        }

        foreach ($teamName in $teams) {
            $teamName = $teamName.Trim()
            if (-not $teamDescriptors.ContainsKey($teamName)) {
                Write-Status "  WARN: Team '$teamName' no encontrado en Graph, omitiendo para '$email'" -Level WARN
                $skipped++
                continue
            }

            $containerDesc = $teamDescriptors[$teamName]
            Pretty-Action "Asignar" "'$email' -> Team '$teamName'"
            if ($Execute) {
                $r = Add-GraphMembership -MemberDescriptor $userDesc -ContainerDescriptor $containerDesc
                if (Test-IsErr $r) {
                    # 409 = ya es miembro
                    $status = if ($r.PSObject.Properties.Match('_status').Count -gt 0) { $r._status } else { "" }
                    if ($status -eq 'Conflict' -or (Get-ErrMsg $r) -match 'already exists|already a member') {
                        Write-Status "    EXISTS: '$email' ya es miembro de '$teamName'" -Level INFO
                        $skipped++
                    } else {
                        Write-Status "    ERROR: $(Get-ErrMsg $r)" -Level ERROR
                        $errors++
                    }
                    continue
                }
                Write-Status "    OK: '$email' asignado a '$teamName'" -Level OK
                $assigned++
            }
        }
    }

    Write-Status "Memberships: $assigned asignadas, $skipped omitidas, $errors errores" -Level OK
}

# ================================================================
# MAIN
# ================================================================
$_toolName    = "Migrate-ProjectUsers"
$_toolVersion = "1.0.0"
$_toolUpdate  = "2025-05-07"

Write-Host ""
Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Magenta
Write-Host "  │                                                          │" -ForegroundColor Magenta
Write-Host "  │   ■ ■  $_toolName  v$_toolVersion                  │" -ForegroundColor Magenta
Write-Host "  │        Last update: $_toolUpdate                        │" -ForegroundColor Magenta
Write-Host "  │        Users & Teams Migration                          │" -ForegroundColor Magenta
Write-Host "  │                                                          │" -ForegroundColor Magenta
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Source : $SourceBaseUrl / $SourceProject" -ForegroundColor Cyan
Write-Host "  Target : $TargetOrgUrl / $TargetProject" -ForegroundColor Cyan
Write-Host "  Modo   : $(if ($Execute) { 'EXECUTE (real)' } else { 'INVENTARIO / DRY-RUN' })" -ForegroundColor Cyan
Write-Host "  Output : $OutputDir" -ForegroundColor Cyan
Write-Host ""

# === SIEMPRE: Inventario ===
$inventory = Get-SourceTeamsInventory
if (-not $inventory) {
    Write-Status "No se pudo obtener inventario del origen. Abortando." -Level ERROR
    exit 1
}

# Guardar inventario completo como JSON
$jsonPath = Join-Path $OutputDir "source-inventory.json"
$inventory | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Status "Inventario guardado en: $jsonPath" -Level OK

# Generar/actualizar CSV manifest
$csvPath = Join-Path $OutputDir "users-manifest.csv"
if (-not $ManifestFile) {
    # Generar CSV template para que el usuario complete
    $inventory.Users | Select-Object SourceUniqueName, SourceDisplayName, SourceEmail, TargetEmail, AccessLevel, GroupType, Teams |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Status "CSV template generado: $csvPath" -Level OK
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║  SIGUIENTE PASO:                                       ║" -ForegroundColor Yellow
    Write-Host "  ║                                                         ║" -ForegroundColor Yellow
    Write-Host "  ║  1. Abra el archivo:                                    ║" -ForegroundColor Yellow
    Write-Host "  ║     $csvPath" -ForegroundColor Yellow
    Write-Host "  ║                                                         ║" -ForegroundColor Yellow
    Write-Host "  ║  2. Complete la columna 'TargetEmail' con el email      ║" -ForegroundColor Yellow
    Write-Host "  ║     de cada usuario en Azure AD (Entra ID).             ║" -ForegroundColor Yellow
    Write-Host "  ║                                                         ║" -ForegroundColor Yellow
    Write-Host "  ║  3. Ajuste 'AccessLevel' (stakeholder/express/advanced) ║" -ForegroundColor Yellow
    Write-Host "  ║     y 'GroupType' si necesita.                          ║" -ForegroundColor Yellow
    Write-Host "  ║                                                         ║" -ForegroundColor Yellow
    Write-Host "  ║  4. Elimine filas de usuarios que NO desea migrar.      ║" -ForegroundColor Yellow
    Write-Host "  ║                                                         ║" -ForegroundColor Yellow
    Write-Host "  ║  5. Vuelva a ejecutar con:                              ║" -ForegroundColor Yellow
    Write-Host "  ║     .\Migrate-ProjectUsers.ps1 \                        ║" -ForegroundColor Yellow
    Write-Host "  ║       -SourceProject '$SourceProject' \                 ║" -ForegroundColor Yellow
    Write-Host "  ║       -ManifestFile '$csvPath' \                        ║" -ForegroundColor Yellow
    Write-Host "  ║       -Execute                                          ║" -ForegroundColor Yellow
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# === EJECUCION: Procesar manifest ===
if (-not (Test-Path $ManifestFile)) {
    Write-Status "ERROR: No se encontro el archivo manifest: $ManifestFile" -Level ERROR
    exit 1
}

$manifest = Import-Csv -Path $ManifestFile -Encoding UTF8
$validEntries = @($manifest | Where-Object { -not [string]::IsNullOrWhiteSpace($_.TargetEmail) })
Write-Status "Manifest cargado: $($manifest.Count) filas, $($validEntries.Count) con TargetEmail" -Level OK

if ($validEntries.Count -eq 0) {
    Write-Status "ERROR: Ningun usuario tiene TargetEmail en el manifest. Complete el CSV primero." -Level ERROR
    exit 1
}

if (-not $Execute) {
    Write-Status "Modo DRY-RUN: no se realizaran cambios. Use -Execute para aplicar." -Level WARN
}

# Obtener project ID del destino
$projectId = Get-TargetProjectId
if (-not $projectId) { exit 1 }
Write-Status "Proyecto destino ID: $projectId" -Level OK

# Fase 2: Alta de usuarios
Provision-Users -Manifest $validEntries -ProjectId $projectId

# Fase 3: Crear Teams
Create-TargetTeams -SourceTeams $inventory.Teams

# Fase 4: Memberships
Assign-TeamMemberships -Manifest $validEntries -ProjectId $projectId

# === RESUMEN ===
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  MIGRACION DE USUARIOS COMPLETADA                      ║" -ForegroundColor Green
Write-Host "  ║                                                         ║" -ForegroundColor Green
Write-Host "  ║  Archivos de salida:                                    ║" -ForegroundColor Green
Write-Host "  ║    - source-inventory.json  (inventario origen)         ║" -ForegroundColor Green
Write-Host "  ║    - mapping-users.json     (usuario -> descriptor)     ║" -ForegroundColor Green
Write-Host "  ║    - mapping-teams.json     (team -> id destino)        ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
