<#
.SYNOPSIS
    Audit-ReposForGitHubMigration.ps1
    Auditoria pre-migracion de repos Git en Azure DevOps Server OnPrem hacia GitHub.

.DESCRIPTION
    Clona repos en modo mirror desde ADO Server y ejecuta:
      1. Deteccion de blobs grandes (>50 MB y >100 MB)
      2. Caracteres especiales en nombres de archivos y repos
      3. Fecha de ultimo commit (clasificacion activo/archive)
      4. Integridad del repo (git fsck)
      5. Indicadores basicos de secrets en archivos tracked
      6. Resumen consolidado en CSV y JSON

.PARAMETER AdoBaseUrl
    URL base de la collection. Ejemplo: https://bcrtfs/tfs/BCRCollection

.PARAMETER ProjectName
    Nombre del Team Project. Ejemplo: TPBCRComercial

.PARAMETER OutputDir
    Directorio donde se guardan los clones y reportes. Default: .\migration-audit

.PARAMETER ThresholdWarnMB
    Umbral de advertencia en MB. Default: 50

.PARAMETER ThresholdBlockMB
    Umbral de bloqueo (GitHub hard limit por archivo). Default: 100

.PARAMETER InactiveMonths
    Meses sin commits para clasificar como inactivo. Default: 12

.PARAMETER RepoFilter
    Filtro opcional por nombre de repo (wildcard). Default: * (todos)

.PARAMETER SkipClone
    Si se especifica, asume que los mirrors ya existen en OutputDir y no hace clone.

.PARAMETER PatToken
    PAT de ADO Server. Si no se provee, usa credenciales default (NTLM/Kerberos).

.EXAMPLE
    .\Audit-ReposForGitHubMigration.ps1 `
        -AdoBaseUrl "https://bcrtfs/tfs/BCRCollection" `
        -ProjectName "TPBCRComercial" `
        -OutputDir "C:\migration-audit" `
        -PatToken $env:ADO_PAT

.EXAMPLE
    .\Audit-ReposForGitHubMigration.ps1 `
        -AdoBaseUrl "https://bcrtfs/tfs/BCRCollection" `
        -ProjectName "TPSistar" `
        -RepoFilter "*worker*"

.NOTES
    Requiere: git.exe en PATH (2.25+)
    Plataforma: Windows PowerShell 5.1+ o PowerShell 7+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdoBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [string]$OutputDir = ".\migration-audit",

    [int]$ThresholdWarnMB = 50,

    [int]$ThresholdBlockMB = 100,

    [int]$InactiveMonths = 12,

    [string]$RepoFilter = "*",

    [switch]$SkipClone,

    [string]$PatToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------
# Funciones auxiliares
# ----------------------------------------------------------------

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "OK"      { "Green" }
        default   { "White" }
    }
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
}

function Test-GitAvailable {
    try {
        $version = & git --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git not found" }
        Write-Status "Git detectado: $version"
        return $true
    }
    catch {
        Write-Status "git.exe no encontrado en PATH. Instalar Git for Windows." -Level "ERROR"
        return $false
    }
}

function Get-RepoListFromApi {
    param([string]$BaseUrl, [string]$Project, [string]$Pat)

    $apiUrl = "$BaseUrl/$Project/_apis/git/repositories?api-version=5.0"
    Write-Status "Consultando API: $apiUrl"

    $headers = @{}
    if ($Pat) {
        $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        $headers["Authorization"] = "Basic $base64"
    }

    try {
        $params = @{
            Uri     = $apiUrl
            Method  = "Get"
            Headers = $headers
        }
        if (-not $Pat) {
            $params["UseDefaultCredentials"] = $true
        }
        $response = Invoke-RestMethod @params
        return $response.value
    }
    catch {
        Write-Status "Error al consultar API: $_" -Level "ERROR"
        Write-Status "Verificar conectividad, credenciales y version de ADO Server." -Level "ERROR"
        throw
    }
}

function Sanitize-RepoName {
    param([string]$Name)
    $sanitized = $Name

    $sanitized = $sanitized -replace [char]0x00E1, 'a'
    $sanitized = $sanitized -replace [char]0x00E9, 'e'
    $sanitized = $sanitized -replace [char]0x00ED, 'i'
    $sanitized = $sanitized -replace [char]0x00F3, 'o'
    $sanitized = $sanitized -replace [char]0x00FA, 'u'
    $sanitized = $sanitized -replace [char]0x00C1, 'A'
    $sanitized = $sanitized -replace [char]0x00C9, 'E'
    $sanitized = $sanitized -replace [char]0x00CD, 'I'
    $sanitized = $sanitized -replace [char]0x00D3, 'O'
    $sanitized = $sanitized -replace [char]0x00DA, 'U'
    $sanitized = $sanitized -replace [char]0x00E0, 'a'
    $sanitized = $sanitized -replace [char]0x00E4, 'a'
    $sanitized = $sanitized -replace [char]0x00E8, 'e'
    $sanitized = $sanitized -replace [char]0x00EB, 'e'
    $sanitized = $sanitized -replace [char]0x00EC, 'i'
    $sanitized = $sanitized -replace [char]0x00EF, 'i'
    $sanitized = $sanitized -replace [char]0x00F2, 'o'
    $sanitized = $sanitized -replace [char]0x00F6, 'o'
    $sanitized = $sanitized -replace [char]0x00F9, 'u'
    $sanitized = $sanitized -replace [char]0x00FC, 'u'
    $sanitized = $sanitized -replace [char]0x00F1, 'n'
    $sanitized = $sanitized -replace [char]0x00D1, 'N'

    $sanitized = $sanitized -replace '\s+', '-'
    $sanitized = $sanitized -replace '[^a-zA-Z0-9._-]', ''
    $sanitized = $sanitized -replace '-{2,}', '-'
    $sanitized = $sanitized.Trim('-')
    return $sanitized
}

function Get-LargeBlobs {
    param(
        [string]$RepoPath,
        [int]$ThresholdBytes
    )

    $results = @()

    Push-Location $RepoPath
    try {
        $objects = & git rev-list --objects --all 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Status "  Error en rev-list: $objects" -Level "WARN"
            return $results
        }

        $tempFile = [System.IO.Path]::GetTempFileName()
        $objects | Out-File -FilePath $tempFile -Encoding ascii

        $blobInfo = & cmd /c "git cat-file --batch-check=""%(objecttype) %(objectsize) %(rest)"" < ""$tempFile"" 2>&1"
        Remove-Item $tempFile -ErrorAction SilentlyContinue

        foreach ($line in $blobInfo) {
            if ($line -match '^blob\s+(\d+)\s+(.*)$') {
                $size = [long]$Matches[1]
                $filePath = $Matches[2].Trim()
                if ($size -ge $ThresholdBytes -and $filePath) {
                    $results += [PSCustomObject]@{
                        Path   = $filePath
                        SizeMB = [math]::Round($size / 1MB, 2)
                        Bytes  = $size
                    }
                }
            }
        }
    }
    finally {
        Pop-Location
    }

    return $results | Sort-Object -Property Bytes -Descending
}

function Get-SpecialCharFiles {
    param([string]$RepoPath)

    $results = @()
    Push-Location $RepoPath
    try {
        $files = & git ls-tree -r --name-only HEAD 2>&1
        if ($LASTEXITCODE -ne 0) { return $results }

        foreach ($f in $files) {
            $issues = @()

            if ($f -match '[^\x00-\x7F]') {
                $issues += "NON_ASCII"
            }
            if ($f -match ' ') {
                $issues += "SPACES"
            }
            if ($f -match '[<>:"|?*]') {
                $issues += "WINDOWS_INVALID"
            }
            if ($f.Length -gt 260) {
                $issues += "PATH_TOO_LONG"
            }

            if ($issues.Count -gt 0) {
                $results += [PSCustomObject]@{
                    FilePath = $f
                    Issues   = ($issues -join ", ")
                }
            }
        }
    }
    finally {
        Pop-Location
    }

    return $results
}

function Get-SecretsIndicators {
    param([string]$RepoPath)

    $results = @()

    $patternNames = @(
        "CONNECTION_STRING",
        "PASSWORD_LITERAL",
        "PRIVATE_KEY",
        "API_KEY_PATTERN",
        "AWS_KEY",
        "BEARER_TOKEN",
        "PFX_OR_CERT"
    )
    $patternRegexes = @(
        '(?i)(connection\s*string|Data Source=|Server=.*Database=)',
        '(?i)(password|passwd|pwd)\s*[=:]\s*[''"][^''"]{4,}',
        '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----',
        '(?i)(api[_\-]?key|apikey|api[_\-]?secret)\s*[=:]\s*[''"][^''"]{8,}',
        '(?i)(AKIA[0-9A-Z]{16})',
        '(?i)bearer\s+[a-zA-Z0-9\-._~+/]{20,}',
        '(?i)\.(pfx|p12|keystore|jks)\b'
    )

    Push-Location $RepoPath
    try {
        $files = & git ls-tree -r --name-only HEAD 2>&1
        if ($LASTEXITCODE -ne 0) { return $results }

        $textExtensions = @('.cs', '.java', '.xml', '.json', '.yml', '.yaml', '.config',
                           '.properties', '.env', '.sh', '.ps1', '.bat', '.cmd', '.tf',
                           '.cfg', '.ini', '.conf', '.toml', '.py', '.js', '.ts',
                           '.csproj', '.sln', '.gradle', '.pom', '.settings', '.txt',
                           '.md', '.dockerfile', '.sql')

        foreach ($file in $files) {
            $ext = [System.IO.Path]::GetExtension($file).ToLower()
            $isRelevant = ($ext -in $textExtensions) -or ($file -match '(?i)(dockerfile|docker-compose|\.env|appsettings|web\.config|app\.config)')
            if (-not $isRelevant) { continue }

            try {
                $content = & git show "HEAD:$file" 2>&1
                if ($LASTEXITCODE -ne 0) { continue }

                $contentStr = $content -join "`n"
                for ($i = 0; $i -lt $patternNames.Count; $i++) {
                    if ($contentStr -match $patternRegexes[$i]) {
                        $results += [PSCustomObject]@{
                            File    = $file
                            Finding = $patternNames[$i]
                        }
                    }
                }
            }
            catch { continue }
        }
    }
    finally {
        Pop-Location
    }

    return $results
}

function Get-RepoLastActivity {
    param([string]$RepoPath)

    Push-Location $RepoPath
    try {
        $logOutput = & git log -1 --format='%ci|%H|%an' HEAD 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $logOutput) {
            return [PSCustomObject]@{
                LastCommitDate = $null
                LastCommitHash = "N/A"
                LastAuthor     = "N/A"
                IsActive       = $false
            }
        }
        $parts = ($logOutput -split '\|')
        $commitDate = [datetime]::Parse($parts[0].Trim())
        $cutoff = (Get-Date).AddMonths(-$InactiveMonths)

        return [PSCustomObject]@{
            LastCommitDate = $commitDate
            LastCommitHash = $parts[1].Trim().Substring(0, 8)
            LastAuthor     = $parts[2].Trim()
            IsActive       = ($commitDate -ge $cutoff)
        }
    }
    catch {
        return [PSCustomObject]@{
            LastCommitDate = $null
            LastCommitHash = "ERROR"
            LastAuthor     = "ERROR"
            IsActive       = $false
        }
    }
    finally {
        Pop-Location
    }
}

function Get-RepoBranchAndTagCount {
    param([string]$RepoPath)

    Push-Location $RepoPath
    try {
        $branches = (& git branch -a 2>&1 | Measure-Object).Count
        $tags = (& git tag 2>&1 | Measure-Object).Count
        $commits = & git rev-list --all --count 2>&1
        return [PSCustomObject]@{
            Branches = $branches
            Tags     = $tags
            Commits  = [int]$commits
        }
    }
    catch {
        return [PSCustomObject]@{ Branches = 0; Tags = 0; Commits = 0 }
    }
    finally {
        Pop-Location
    }
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Auditoria Pre-Migracion ADO Server -> GitHub" -ForegroundColor Cyan
Write-Host "  Proyecto: $ProjectName" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-GitAvailable)) { exit 1 }

$mirrorsDir = Join-Path $OutputDir "mirrors" $ProjectName
$reportsDir = Join-Path $OutputDir "reports"
New-Item -ItemType Directory -Path $mirrorsDir -Force | Out-Null
New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null

Write-Status "Obteniendo lista de repos para $ProjectName..."
$repos = Get-RepoListFromApi -BaseUrl $AdoBaseUrl -Project $ProjectName -Pat $PatToken

if ($RepoFilter -ne "*") {
    $repos = $repos | Where-Object { $_.name -like $RepoFilter }
}

$totalRepos = ($repos | Measure-Object).Count
Write-Status "Repos encontrados: $totalRepos (filtro: $RepoFilter)"

if ($totalRepos -eq 0) {
    Write-Status "No se encontraron repos. Verificar el proyecto y filtro." -Level "WARN"
    exit 0
}

$auditResults = @()
$nameMappings = @()
$allLargeBlobs = @()
$allSpecialCharFiles = @()
$allSecretsFindings = @()

$thresholdWarnBytes = $ThresholdWarnMB * 1MB
$thresholdBlockBytes = $ThresholdBlockMB * 1MB
$repoIndex = 0

foreach ($repo in $repos) {
    $repoIndex++
    $repoName = $repo.name
    $repoUrl = $repo.remoteUrl

    Write-Host ""
    Write-Status "[$repoIndex/$totalRepos] $repoName" -Level "INFO"

    if (-not $repo.defaultBranch) {
        Write-Status "  Repo vacio (sin default branch). Saltando." -Level "WARN"
        $auditResults += [PSCustomObject]@{
            Repository        = $repoName
            GitHubName        = Sanitize-RepoName $repoName
            NameChanged       = ($repoName -ne (Sanitize-RepoName $repoName))
            Status            = "EMPTY"
            SizeMB            = 0
            Commits           = 0
            Branches          = 0
            Tags              = 0
            LastCommit        = $null
            LastAuthor        = "N/A"
            IsActive          = $false
            BlobsOver50MB     = 0
            BlobsOver100MB    = 0
            LargestBlobMB     = 0
            SpecialCharFiles  = 0
            SecretsIndicators = 0
            FsckClean         = $false
            MigrationRisk     = "SKIP"
        }
        continue
    }

    $sanitizedName = Sanitize-RepoName $repoName
    if ($repoName -ne $sanitizedName) {
        Write-Status "  Nombre requiere sanitizacion: $repoName -> $sanitizedName" -Level "WARN"
        $nameMappings += [PSCustomObject]@{
            Original  = $repoName
            Sanitized = $sanitizedName
            Project   = $ProjectName
        }
    }

    $mirrorPath = Join-Path $mirrorsDir "$repoName.git"

    if (-not $SkipClone) {
        if (Test-Path $mirrorPath) {
            Write-Status "  Mirror existe, actualizando..."
            Push-Location $mirrorPath
            & git remote update origin --prune 2>&1 | Out-Null
            Pop-Location
        }
        else {
            Write-Status "  Clonando mirror..."
            $cloneUrl = $repoUrl
            if ($PatToken) {
                $cloneUrl = $repoUrl -replace '(https?://)', "`$1user:$PatToken@"
            }
            & git clone --mirror $cloneUrl $mirrorPath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Status "  Error en clone. Saltando." -Level "ERROR"
                $auditResults += [PSCustomObject]@{
                    Repository        = $repoName
                    GitHubName        = $sanitizedName
                    NameChanged       = ($repoName -ne $sanitizedName)
                    Status            = "CLONE_FAILED"
                    SizeMB            = 0
                    Commits           = 0
                    Branches          = 0
                    Tags              = 0
                    LastCommit        = $null
                    LastAuthor        = "N/A"
                    IsActive          = $false
                    BlobsOver50MB     = 0
                    BlobsOver100MB    = 0
                    LargestBlobMB     = 0
                    SpecialCharFiles  = 0
                    SecretsIndicators = 0
                    FsckClean         = $false
                    MigrationRisk     = "ERROR"
                }
                continue
            }
        }
    }

    if (-not (Test-Path $mirrorPath)) {
        Write-Status "  Mirror no encontrado en $mirrorPath. Usar -SkipClone solo si ya se clono." -Level "ERROR"
        continue
    }

    # 1. Blobs grandes
    Write-Status "  Escaneando blobs grandes..."
    $largeBlobs = Get-LargeBlobs -RepoPath $mirrorPath -ThresholdBytes $thresholdWarnBytes
    $blobsOver50 = ($largeBlobs | Where-Object { $_.Bytes -ge $thresholdWarnBytes } | Measure-Object).Count
    $blobsOver100 = ($largeBlobs | Where-Object { $_.Bytes -ge $thresholdBlockBytes } | Measure-Object).Count
    $largestBlob = if ($largeBlobs.Count -gt 0) { $largeBlobs[0].SizeMB } else { 0 }

    if ($blobsOver100 -gt 0) {
        Write-Status "  BLOCKER: $blobsOver100 archivo(s) >100 MB. GitHub rechazara el push." -Level "ERROR"
    }
    elseif ($blobsOver50 -gt 0) {
        Write-Status "  WARNING: $blobsOver50 archivo(s) >50 MB." -Level "WARN"
    }

    foreach ($blob in $largeBlobs) {
        $allLargeBlobs += [PSCustomObject]@{
            Repository = $repoName
            FilePath   = $blob.Path
            SizeMB     = $blob.SizeMB
            Blocked    = ($blob.Bytes -ge $thresholdBlockBytes)
        }
    }

    # 2. Caracteres especiales en archivos
    Write-Status "  Escaneando caracteres especiales en archivos..."
    $specialFiles = Get-SpecialCharFiles -RepoPath $mirrorPath
    if ($specialFiles.Count -gt 0) {
        Write-Status "  $($specialFiles.Count) archivo(s) con caracteres especiales." -Level "WARN"
    }
    foreach ($sf in $specialFiles) {
        $allSpecialCharFiles += [PSCustomObject]@{
            Repository = $repoName
            FilePath   = $sf.FilePath
            Issues     = $sf.Issues
        }
    }

    # 3. Ultima actividad
    Write-Status "  Verificando ultima actividad..."
    $activity = Get-RepoLastActivity -RepoPath $mirrorPath
    if (-not $activity.IsActive) {
        Write-Status "  Inactivo: ultimo commit $($activity.LastCommitDate)" -Level "WARN"
    }

    # 4. Stats
    $stats = Get-RepoBranchAndTagCount -RepoPath $mirrorPath

    # 5. fsck
    Write-Status "  Verificando integridad (fsck)..."
    Push-Location $mirrorPath
    $fsckOutput = & git fsck --full 2>&1
    $fsckClean = ($LASTEXITCODE -eq 0)
    Pop-Location
    if (-not $fsckClean) {
        Write-Status "  fsck reporto problemas." -Level "WARN"
    }

    # 6. Secrets
    Write-Status "  Escaneando indicadores de secrets..."
    $secrets = Get-SecretsIndicators -RepoPath $mirrorPath
    if ($secrets.Count -gt 0) {
        Write-Status "  $($secrets.Count) indicador(es) de secrets detectados." -Level "WARN"
    }
    foreach ($s in $secrets) {
        $allSecretsFindings += [PSCustomObject]@{
            Repository = $repoName
            File       = $s.File
            Finding    = $s.Finding
        }
    }

    $repoSizeMB = [math]::Round((Get-ChildItem $mirrorPath -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB, 2)

    $risk = "LOW"
    if ($blobsOver100 -gt 0) {
        $risk = "BLOCKED"
    }
    elseif ($blobsOver50 -gt 0 -or $secrets.Count -gt 0) {
        $risk = "HIGH"
    }
    elseif ($specialFiles.Count -gt 0 -or (-not $activity.IsActive)) {
        $risk = "MEDIUM"
    }

    $repoStatus = "ACTIVE"
    if (-not $activity.IsActive) {
        $repoStatus = "INACTIVE"
    }

    $auditResults += [PSCustomObject]@{
        Repository        = $repoName
        GitHubName        = $sanitizedName
        NameChanged       = ($repoName -ne $sanitizedName)
        Status            = $repoStatus
        SizeMB            = $repoSizeMB
        Commits           = $stats.Commits
        Branches          = $stats.Branches
        Tags              = $stats.Tags
        LastCommit        = $activity.LastCommitDate
        LastAuthor        = $activity.LastAuthor
        IsActive          = $activity.IsActive
        BlobsOver50MB     = $blobsOver50
        BlobsOver100MB    = $blobsOver100
        LargestBlobMB     = $largestBlob
        SpecialCharFiles  = $specialFiles.Count
        SecretsIndicators = $secrets.Count
        FsckClean         = $fsckClean
        MigrationRisk     = $risk
    }

    $riskColor = switch ($risk) {
        "BLOCKED" { "Red" }
        "HIGH"    { "Red" }
        "MEDIUM"  { "Yellow" }
        "LOW"     { "Green" }
        default   { "White" }
    }
    Write-Host "  Resultado: $risk" -ForegroundColor $riskColor
}

# ----------------------------------------------------------------
# Generar reportes
# ----------------------------------------------------------------

Write-Host ""
Write-Status "Generando reportes..."

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$baseFileName = "${ProjectName}_audit_${timestamp}"

$csvPath = Join-Path $reportsDir "${baseFileName}.csv"
$auditResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Reporte principal: $csvPath"

if ($allLargeBlobs.Count -gt 0) {
    $blobsCsv = Join-Path $reportsDir "${baseFileName}_large_blobs.csv"
    $allLargeBlobs | Export-Csv -Path $blobsCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Blobs grandes: $blobsCsv"
}

if ($allSpecialCharFiles.Count -gt 0) {
    $charsCsv = Join-Path $reportsDir "${baseFileName}_special_chars.csv"
    $allSpecialCharFiles | Export-Csv -Path $charsCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Caracteres especiales: $charsCsv"
}

if ($allSecretsFindings.Count -gt 0) {
    $secretsCsv = Join-Path $reportsDir "${baseFileName}_secrets.csv"
    $allSecretsFindings | Export-Csv -Path $secretsCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Indicadores de secrets: $secretsCsv"
}

if ($nameMappings.Count -gt 0) {
    $mappingCsv = Join-Path $reportsDir "${baseFileName}_name_mappings.csv"
    $nameMappings | Export-Csv -Path $mappingCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Mapeo de nombres: $mappingCsv"
}

$jsonPath = Join-Path $reportsDir "${baseFileName}.json"

$activeCount = ($auditResults | Where-Object { $_.Status -eq "ACTIVE" } | Measure-Object).Count
$inactiveCount = ($auditResults | Where-Object { $_.Status -eq "INACTIVE" } | Measure-Object).Count
$emptyCount = ($auditResults | Where-Object { $_.Status -eq "EMPTY" } | Measure-Object).Count
$blockedCount = ($auditResults | Where-Object { $_.MigrationRisk -eq "BLOCKED" } | Measure-Object).Count
$highCount = ($auditResults | Where-Object { $_.MigrationRisk -eq "HIGH" } | Measure-Object).Count
$mediumCount = ($auditResults | Where-Object { $_.MigrationRisk -eq "MEDIUM" } | Measure-Object).Count
$lowCount = ($auditResults | Where-Object { $_.MigrationRisk -eq "LOW" } | Measure-Object).Count
$totalSizeMB = [math]::Round(($auditResults | Measure-Object -Property SizeMB -Sum).Sum, 2)
$secretsRepoCount = ($auditResults | Where-Object { $_.SecretsIndicators -gt 0 } | Measure-Object).Count

$summary = [PSCustomObject]@{
    AuditDate            = (Get-Date -Format "o")
    Project              = $ProjectName
    AdoBaseUrl           = $AdoBaseUrl
    TotalRepos           = $totalRepos
    ActiveRepos          = $activeCount
    InactiveRepos        = $inactiveCount
    EmptyRepos           = $emptyCount
    BlockedRepos         = $blockedCount
    HighRiskRepos        = $highCount
    MediumRiskRepos      = $mediumCount
    LowRiskRepos         = $lowCount
    TotalSizeMB          = $totalSizeMB
    ReposWithSecrets     = $secretsRepoCount
    NamesRequiringChange = $nameMappings.Count
    Repos                = $auditResults
    LargeBlobs           = $allLargeBlobs
    SecretsFindings      = $allSecretsFindings
    NameMappings         = $nameMappings
}

$summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Status "JSON consolidado: $jsonPath"

# ----------------------------------------------------------------
# Resumen en consola
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                  RESUMEN DE AUDITORIA" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Proyecto:           $ProjectName" -ForegroundColor White
Write-Host "  Total repos:        $totalRepos" -ForegroundColor White
Write-Host "  Activos:            $activeCount" -ForegroundColor Green
Write-Host "  Inactivos:          $inactiveCount" -ForegroundColor Yellow
Write-Host "  Vacios:             $emptyCount" -ForegroundColor DarkGray
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  BLOCKED:            $blockedCount" -ForegroundColor Red
Write-Host "  HIGH:               $highCount" -ForegroundColor Red
Write-Host "  MEDIUM:             $mediumCount" -ForegroundColor Yellow
Write-Host "  LOW:                $lowCount" -ForegroundColor Green
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Tamano total:       $totalSizeMB MB" -ForegroundColor White

$nameColor = if ($nameMappings.Count -gt 0) { "Yellow" } else { "White" }
Write-Host "  Nombres a cambiar:  $($nameMappings.Count)" -ForegroundColor $nameColor

$secretsColor = if ($secretsRepoCount -gt 0) { "Red" } else { "White" }
Write-Host "  Repos con secrets:  $secretsRepoCount" -ForegroundColor $secretsColor
Write-Host "================================================================" -ForegroundColor Cyan

if ($blockedCount -gt 0) {
    Write-Host ""
    Write-Status "REPOS BLOQUEADOS (archivos >100 MB, GitHub rechazara push):" -Level "ERROR"
    $auditResults | Where-Object { $_.MigrationRisk -eq "BLOCKED" } | ForEach-Object {
        Write-Host "  - $($_.Repository): mayor blob = $($_.LargestBlobMB) MB" -ForegroundColor Red
    }
    Write-Host ""
    Write-Status "Opciones: git filter-repo, Git LFS, o shallow migration. Decidir antes de continuar." -Level "WARN"
}

Write-Host ""
Write-Status "Auditoria completada. Reportes en: $reportsDir" -Level "OK"
