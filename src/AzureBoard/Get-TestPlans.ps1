<#
.SYNOPSIS
    Get-TestPlans.ps1
    Inventario de Test Plans en Azure DevOps Server OnPrem.

.DESCRIPTION
    Consulta las APIs REST de Azure DevOps para cada proyecto y obtiene:
      1. Lista de Test Plans con su estado (Active, Inactive)
      2. Test Suites por cada plan
      3. Conteo de Test Cases por suite
      4. Resumen de Test Points (estado de ejecucion)
      5. Estadisticas consolidadas por proyecto
    Genera CSV y JSON con los resultados.

.PARAMETER AdoBaseUrl
    URL base de la collection. Si no se provee, se lee $env:ADO_BASE (desde .env).

.PARAMETER ProjectFilter
    Filtro opcional por nombre de proyecto (wildcard). Default: * (todos)

.PARAMETER TeamProject
    Nombre exacto de un unico Team Project a auditar. Si se provee, tiene
    precedencia sobre -ProjectFilter y solo se audita ese proyecto.

.PARAMETER OutputDir
    Directorio de salida para reportes. Default: .\testplans-inventory

.PARAMETER PatToken
    PAT de ADO Server. Si no se provee, se lee $env:ADO_PAT (desde .env).
    Si no hay PAT, usa credenciales default (NTLM/Kerberos).

.PARAMETER EnvFile
    Ruta al archivo .env con la configuracion. Default: ./.env (junto al script).

.PARAMETER ApiVersion
    Version de la API REST. Default: 5.0 (compatible con ADO Server 2019+)

.PARAMETER IncludeTestCases
    Si se activa, descarga el detalle de test cases por suite. Default: $false
    NOTA: Puede ser lento en proyectos con muchos test cases.

.PARAMETER ExcludeProjects
    Lista de nombres de Team Projects a excluir del analisis.
    Soporta wildcards (ej: "Test*", "*Backup").

.PARAMETER LogFile
    Ruta del archivo de log. Si no se especifica, se crea automaticamente
    en OutputDir con timestamp.

.EXAMPLE
    # Usando .env (ADO_BASE y ADO_PAT)
    .\Get-TestPlans.ps1

.EXAMPLE
    .\Get-TestPlans.ps1 -ProjectFilter "TP*"

.EXAMPLE
    # Obtener test plans de un unico Team Project
    .\Get-TestPlans.ps1 -TeamProject "MiProyecto"

.EXAMPLE
    # Incluir detalle de test cases (puede ser lento)
    .\Get-TestPlans.ps1 -TeamProject "MiProyecto" -IncludeTestCases $true

.EXAMPLE
    .\Get-TestPlans.ps1 -AdoBaseUrl "https://server/tfs/Collection" -PatToken $env:ADO_PAT

.EXAMPLE
    # Excluir proyectos especificos
    .\Get-TestPlans.ps1 -ExcludeProjects @("TestProject", "Sandbox*")

.NOTES
    Requiere: Conectividad a ADO Server, PowerShell 5.1+
    Operacion: Solo lectura. No modifica nada en el servidor.
    API usada: _apis/test/plans (Azure DevOps Server 2019+)
#>

[CmdletBinding()]
param(
    [string]$AdoBaseUrl,

    [string]$ProjectFilter = "*",

    [string]$TeamProject,

    [string]$OutputDir = ".\testplans-inventory",

    [string]$PatToken,

    [string]$EnvFile = (Join-Path (Split-Path $PSScriptRoot -Parent) ".env"),

    [string]$ApiVersion = "5.0",

    [bool]$IncludeTestCases = $false,

    [string[]]$ExcludeProjects,

    [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ----------------------------------------------------------------
# CARGA DE .env
# ----------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "INFO: No se encontro archivo .env en '$Path'. Se usaran variables de entorno actuales." -ForegroundColor DarkYellow
        return
    }
    Write-Host "INFO: Cargando configuracion desde $Path" -ForegroundColor DarkCyan
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

if (-not $AdoBaseUrl) { $AdoBaseUrl = $env:ADO_BASE }
if (-not $PatToken)   { $PatToken   = $env:ADO_PAT }

if (-not $AdoBaseUrl) {
    Write-Host "ERROR: Falta AdoBaseUrl. Pasa -AdoBaseUrl o define ADO_BASE en .env" -ForegroundColor Red
    exit 1
}
if (-not $PatToken) {
    Write-Host "WARN: No se definio ADO_PAT. Se usaran credenciales Windows (NTLM/Kerberos)." -ForegroundColor Yellow
}

# ----------------------------------------------------------------
# Funciones auxiliares
# ----------------------------------------------------------------
$script:LogFilePath = $null

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
    $logLine = "[$timestamp][$Level] $Message"
    Write-Host $logLine -ForegroundColor $color
    if ($script:LogFilePath) {
        $logLine | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
}

function Write-LogOnly {
    param([string]$Message)
    if ($script:LogFilePath) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        "[$timestamp] $Message" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
}

function Test-ProjectExcluded {
    param(
        [string]$ProjectName,
        [string[]]$ExcludePatterns
    )
    if (-not $ExcludePatterns -or $ExcludePatterns.Count -eq 0) {
        return $false
    }
    foreach ($pattern in $ExcludePatterns) {
        if ($ProjectName -like $pattern) {
            return $true
        }
    }
    return $false
}

function Invoke-AdoApi {
    param(
        [string]$Url,
        [string]$Pat
    )

    $headers = @{}
    if ($Pat) {
        $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        $headers["Authorization"] = "Basic $base64"
    }

    $params = @{
        Uri         = $Url
        Method      = "Get"
        Headers     = $headers
        ContentType = "application/json"
    }
    if (-not $Pat) {
        $params["UseDefaultCredentials"] = $true
    }

    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $statusCode = "Unknown"
        $errorMessage = "Unknown error"
        try {
            if ($null -ne $_.Exception) {
                $errorMessage = $_.Exception.Message
                try {
                    if ($null -ne $_.Exception.Response) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    }
                }
                catch { }
            }
        }
        catch {
            $errorMessage = "Error desconocido al procesar excepcion"
        }
        return [PSCustomObject]@{
            _error      = $true
            _statusCode = $statusCode
            _message    = $errorMessage
            _url        = $Url
        }
    }
}

function Test-IsApiError {
    param($Response)
    if ($null -eq $Response) { return $true }
    if ($Response.PSObject.Properties.Match('_error').Count -gt 0) {
        return [bool]$Response._error
    }
    return $false
}

function Get-ApiErrorMessage {
    param($Response)
    if ($null -eq $Response) { return "Null response" }
    if ($Response.PSObject.Properties.Match('_message').Count -gt 0) { return $Response._message }
    return "Unknown error"
}

# ----------------------------------------------------------------
# Funciones de consulta de Test Plans
# ----------------------------------------------------------------

function Get-TestPlansForProject {
    <#
    .SYNOPSIS
        Obtiene todos los Test Plans de un proyecto.
    #>
    param(
        [string]$BaseUrl,
        [string]$ProjectName,
        [string]$Pat,
        [string]$ApiVer
    )

    $url = "$BaseUrl/$ProjectName/_apis/test/plans?api-version=$ApiVer"
    Write-LogOnly "  GET Test Plans: $url"
    $response = Invoke-AdoApi -Url $url -Pat $Pat
    return $response
}

function Get-TestSuitesForPlan {
    <#
    .SYNOPSIS
        Obtiene las Test Suites de un Test Plan.
    #>
    param(
        [string]$BaseUrl,
        [string]$ProjectName,
        [int]$PlanId,
        [string]$Pat,
        [string]$ApiVer
    )

    $url = "$BaseUrl/$ProjectName/_apis/test/plans/$PlanId/suites?api-version=$ApiVer"
    Write-LogOnly "    GET Suites for Plan $PlanId : $url"
    $response = Invoke-AdoApi -Url $url -Pat $Pat
    return $response
}

function Get-TestCasesForSuite {
    <#
    .SYNOPSIS
        Obtiene los Test Cases de una Test Suite.
    #>
    param(
        [string]$BaseUrl,
        [string]$ProjectName,
        [int]$PlanId,
        [int]$SuiteId,
        [string]$Pat,
        [string]$ApiVer
    )

    $url = "$BaseUrl/$ProjectName/_apis/test/plans/$PlanId/suites/$SuiteId/testcases?api-version=$ApiVer"
    Write-LogOnly "      GET TestCases for Suite $SuiteId in Plan $PlanId"
    $response = Invoke-AdoApi -Url $url -Pat $Pat
    return $response
}

function Get-TestPointsForSuite {
    <#
    .SYNOPSIS
        Obtiene los Test Points (estado de ejecucion) de una Suite.
    #>
    param(
        [string]$BaseUrl,
        [string]$ProjectName,
        [int]$PlanId,
        [int]$SuiteId,
        [string]$Pat,
        [string]$ApiVer
    )

    $url = "$BaseUrl/$ProjectName/_apis/test/plans/$PlanId/suites/$SuiteId/points?api-version=$ApiVer"
    Write-LogOnly "      GET TestPoints for Suite $SuiteId in Plan $PlanId"
    $response = Invoke-AdoApi -Url $url -Pat $Pat
    return $response
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Test Plans Inventory - Azure DevOps Server OnPrem" -ForegroundColor Cyan
Write-Host "  Collection: $AdoBaseUrl" -ForegroundColor Cyan
Write-Host "  Filtro:     $(if ($TeamProject) { $TeamProject } else { $ProjectFilter })" -ForegroundColor Cyan
Write-Host "  Test Cases: $(if ($IncludeTestCases) { 'SI' } else { 'NO' })" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Crear directorio de salida
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Configurar log
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not $LogFile) {
    $LogFile = Join-Path $OutputDir "testplans_inventory_$logTimestamp.log"
}
$script:LogFilePath = $LogFile

"=" * 80 | Out-File -FilePath $script:LogFilePath -Encoding UTF8
"Test Plans Inventory" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"Collection: $AdoBaseUrl" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
"" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8

Write-Status "Archivo de log: $script:LogFilePath" -Level "OK"

# ----------------------------------------------------------------
# Paso 1: Obtener lista de proyectos
# ----------------------------------------------------------------
Write-Status "Obteniendo lista de proyectos..."

$projectsUrl = "$AdoBaseUrl/_apis/projects?`$top=1000&api-version=$ApiVersion"
$projectsResponse = Invoke-AdoApi -Url $projectsUrl -Pat $PatToken

if (Test-IsApiError $projectsResponse) {
    Write-Status "Error al obtener proyectos: $(Get-ApiErrorMessage $projectsResponse)" -Level "ERROR"
    exit 1
}

$allProjects = @($projectsResponse.value)
Write-Status "Total de proyectos en la collection: $($allProjects.Count)" -Level "OK"

# Filtrar proyectos
if ($TeamProject) {
    $filteredProjects = @($allProjects | Where-Object { $_.name -eq $TeamProject })
    if ($filteredProjects.Count -eq 0) {
        Write-Status "No se encontro el proyecto '$TeamProject'" -Level "ERROR"
        exit 1
    }
}
else {
    $filteredProjects = @($allProjects | Where-Object { $_.name -like $ProjectFilter })
}

# Excluir proyectos si se especificaron
if ($ExcludeProjects -and $ExcludeProjects.Count -gt 0) {
    $beforeCount = $filteredProjects.Count
    $filteredProjects = @($filteredProjects | Where-Object {
        -not (Test-ProjectExcluded -ProjectName $_.name -ExcludePatterns $ExcludeProjects)
    })
    $excludedCount = $beforeCount - $filteredProjects.Count
    if ($excludedCount -gt 0) {
        Write-Status "Excluidos $excludedCount proyectos por filtro de exclusion" -Level "WARN"
    }
}

$filteredProjects = @($filteredProjects | Sort-Object -Property name)
Write-Status "Proyectos a analizar: $($filteredProjects.Count)" -Level "OK"

# ----------------------------------------------------------------
# Paso 2: Iterar proyectos y obtener Test Plans
# ----------------------------------------------------------------
Write-Host ""
Write-Status "Iniciando inventario de Test Plans..." -Level "OK"

$allTestPlanResults = @()
$allSuiteResults = @()
$allTestCaseResults = @()
$projectSummaries = @()
$globalStartTime = Get-Date
$projectIndex = 0
$totalProjects = $filteredProjects.Count

foreach ($project in $filteredProjects) {
    $projectIndex++
    $projectName = $project.name
    $projectId = $project.id

    Write-Host ""
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Status "[$projectIndex/$totalProjects] Proyecto: $projectName" -Level "OK"
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan

    $projectStartTime = Get-Date

    # Obtener Test Plans
    $plansResponse = Get-TestPlansForProject -BaseUrl $AdoBaseUrl -ProjectName $projectName -Pat $PatToken -ApiVer $ApiVersion

    if (Test-IsApiError $plansResponse) {
        $errMsg = Get-ApiErrorMessage $plansResponse
        Write-Status "  Error obteniendo Test Plans: $errMsg" -Level "ERROR"
        $projectSummaries += [PSCustomObject]@{
            Project         = $projectName
            ProjectId       = $projectId
            Status          = "ERROR"
            ErrorDetail     = $errMsg
            TestPlanCount   = 0
            ActivePlans     = 0
            InactivePlans   = 0
            TotalSuites     = 0
            TotalTestCases  = 0
            TotalTestPoints = 0
        }
        continue
    }

    $plans = @()
    if ($null -ne $plansResponse.value) {
        $plans = @($plansResponse.value)
    }

    if ($plans.Count -eq 0) {
        Write-Status "  Sin Test Plans" -Level "INFO"
        $projectSummaries += [PSCustomObject]@{
            Project         = $projectName
            ProjectId       = $projectId
            Status          = "OK"
            ErrorDetail     = ""
            TestPlanCount   = 0
            ActivePlans     = 0
            InactivePlans   = 0
            TotalSuites     = 0
            TotalTestCases  = 0
            TotalTestPoints = 0
        }
        continue
    }

    Write-Status "  Test Plans encontrados: $($plans.Count)" -Level "OK"

    $projectTotalSuites = 0
    $projectTotalTestCases = 0
    $projectTotalTestPoints = 0
    $activePlans = 0
    $inactivePlans = 0
    $planIndex = 0

    foreach ($plan in $plans) {
        $planIndex++
        $planId = $plan.id
        $planName = $plan.name
        $planState = if ($plan.PSObject.Properties.Match('state').Count -gt 0) { $plan.state } else { "Unknown" }
        $planOwner = ""
        if ($plan.PSObject.Properties.Match('owner').Count -gt 0 -and $null -ne $plan.owner) {
            $planOwner = if ($plan.owner.PSObject.Properties.Match('displayName').Count -gt 0) { $plan.owner.displayName } else { "" }
        }
        $planStartDate = if ($plan.PSObject.Properties.Match('startDate').Count -gt 0) { $plan.startDate } else { "" }
        $planEndDate = if ($plan.PSObject.Properties.Match('endDate').Count -gt 0) { $plan.endDate } else { "" }
        $planRevision = if ($plan.PSObject.Properties.Match('revision').Count -gt 0) { $plan.revision } else { 0 }
        $planAreaPath = if ($plan.PSObject.Properties.Match('area').Count -gt 0 -and $null -ne $plan.area) {
            if ($plan.area.PSObject.Properties.Match('name').Count -gt 0) { $plan.area.name } else { "" }
        } else { "" }
        $planIteration = if ($plan.PSObject.Properties.Match('iteration').Count -gt 0) { $plan.iteration } else { "" }

        if ($planState -eq "Active") { $activePlans++ } else { $inactivePlans++ }

        Write-Host "    Plan [$planIndex/$($plans.Count)]: $planName (ID:$planId, Estado:$planState)" -ForegroundColor DarkGray

        # Obtener Suites del plan
        $suitesResponse = Get-TestSuitesForPlan -BaseUrl $AdoBaseUrl -ProjectName $projectName -PlanId $planId -Pat $PatToken -ApiVer $ApiVersion

        $planSuiteCount = 0
        $planTestCaseCount = 0
        $planTestPointCount = 0

        if (-not (Test-IsApiError $suitesResponse) -and $null -ne $suitesResponse.value) {
            $suites = @($suitesResponse.value)
            $planSuiteCount = $suites.Count
            $projectTotalSuites += $planSuiteCount

            $suiteIndex = 0
            foreach ($suite in $suites) {
                $suiteIndex++
                $suiteId = $suite.id
                $suiteName = if ($suite.PSObject.Properties.Match('name').Count -gt 0) { $suite.name } else { "Suite-$suiteId" }
                $suiteType = if ($suite.PSObject.Properties.Match('suiteType').Count -gt 0) { $suite.suiteType } else { "Unknown" }
                $suiteTestCaseCount = if ($suite.PSObject.Properties.Match('testCaseCount').Count -gt 0) { [int]$suite.testCaseCount } else { 0 }
                $parentSuiteId = ""
                if ($suite.PSObject.Properties.Match('parent').Count -gt 0 -and $null -ne $suite.parent) {
                    if ($suite.parent.PSObject.Properties.Match('id').Count -gt 0) { $parentSuiteId = $suite.parent.id }
                }

                $planTestCaseCount += $suiteTestCaseCount

                # Registrar suite
                $allSuiteResults += [PSCustomObject]@{
                    Project        = $projectName
                    PlanId         = $planId
                    PlanName       = $planName
                    PlanState      = $planState
                    SuiteId        = $suiteId
                    SuiteName      = $suiteName
                    SuiteType      = $suiteType
                    TestCaseCount  = $suiteTestCaseCount
                    ParentSuiteId  = $parentSuiteId
                }

                # Obtener Test Cases si se solicito
                if ($IncludeTestCases -and $suiteTestCaseCount -gt 0) {
                    $tcResponse = Get-TestCasesForSuite -BaseUrl $AdoBaseUrl -ProjectName $projectName `
                        -PlanId $planId -SuiteId $suiteId -Pat $PatToken -ApiVer $ApiVersion

                    if (-not (Test-IsApiError $tcResponse) -and $null -ne $tcResponse.value) {
                        foreach ($tc in $tcResponse.value) {
                            $tcId = ""
                            $tcName = ""
                            $tcState = ""
                            $tcPriority = ""

                            if ($tc.PSObject.Properties.Match('testCase').Count -gt 0 -and $null -ne $tc.testCase) {
                                $tcId = if ($tc.testCase.PSObject.Properties.Match('id').Count -gt 0) { $tc.testCase.id } else { "" }
                                $tcName = if ($tc.testCase.PSObject.Properties.Match('name').Count -gt 0) { $tc.testCase.name } else { "" }
                            }
                            if ($tc.PSObject.Properties.Match('pointAssignments').Count -gt 0 -and $null -ne $tc.pointAssignments) {
                                $planTestPointCount += @($tc.pointAssignments).Count
                            }

                            $allTestCaseResults += [PSCustomObject]@{
                                Project    = $projectName
                                PlanId     = $planId
                                PlanName   = $planName
                                SuiteId    = $suiteId
                                SuiteName  = $suiteName
                                TestCaseId = $tcId
                                TestCaseName = $tcName
                            }
                        }
                    }
                }

                # Progreso dentro del plan (cada 10 suites)
                if ($suiteIndex % 10 -eq 0) {
                    Write-Host "      Suites procesadas: $suiteIndex/$planSuiteCount" -ForegroundColor DarkGray
                }
            }
        }
        elseif (Test-IsApiError $suitesResponse) {
            Write-Status "    Error obteniendo suites del plan $planId : $(Get-ApiErrorMessage $suitesResponse)" -Level "WARN"
        }

        $projectTotalTestCases += $planTestCaseCount
        $projectTotalTestPoints += $planTestPointCount

        # Registrar plan
        $allTestPlanResults += [PSCustomObject]@{
            Project        = $projectName
            ProjectId      = $projectId
            PlanId         = $planId
            PlanName       = $planName
            PlanState      = $planState
            Owner          = $planOwner
            StartDate      = $planStartDate
            EndDate        = $planEndDate
            Revision       = $planRevision
            AreaPath       = $planAreaPath
            Iteration      = $planIteration
            SuiteCount     = $planSuiteCount
            TestCaseCount  = $planTestCaseCount
            TestPointCount = $planTestPointCount
        }
    }

    $projectElapsed = (Get-Date) - $projectStartTime
    $globalElapsed = (Get-Date) - $globalStartTime

    $projectSummaries += [PSCustomObject]@{
        Project         = $projectName
        ProjectId       = $projectId
        Status          = "OK"
        ErrorDetail     = ""
        TestPlanCount   = $plans.Count
        ActivePlans     = $activePlans
        InactivePlans   = $inactivePlans
        TotalSuites     = $projectTotalSuites
        TotalTestCases  = $projectTotalTestCases
        TotalTestPoints = $projectTotalTestPoints
    }

    Write-Status "  Resumen: $($plans.Count) planes ($activePlans activos), $projectTotalSuites suites, $projectTotalTestCases test cases" -Level "OK"
    Write-Host "  >> Progreso: $projectIndex/$totalProjects proyectos | Tiempo: $($globalElapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Magenta
    Write-LogOnly "Project $projectName completed: $($plans.Count) plans, $projectTotalSuites suites, $projectTotalTestCases test cases, elapsed=$($projectElapsed.ToString('mm\:ss'))"
}

# ----------------------------------------------------------------
# Paso 3: Generar reportes
# ----------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Status "Generando reportes..." -Level "OK"

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$baseFileName = "testplans_inventory_$timestamp"

# CSV resumen por proyecto
$summaryCsvPath = Join-Path $OutputDir "${baseFileName}_projects.csv"
$projectSummaries | Export-Csv -Path $summaryCsvPath -NoTypeInformation -Encoding UTF8
Write-Status "CSV resumen proyectos: $summaryCsvPath" -Level "OK"

# CSV de todos los Test Plans
if ($allTestPlanResults.Count -gt 0) {
    $plansCsvPath = Join-Path $OutputDir "${baseFileName}_plans.csv"
    $allTestPlanResults | Export-Csv -Path $plansCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "CSV test plans: $plansCsvPath ($($allTestPlanResults.Count) planes)" -Level "OK"
}

# CSV de todas las Suites
if ($allSuiteResults.Count -gt 0) {
    $suitesCsvPath = Join-Path $OutputDir "${baseFileName}_suites.csv"
    $allSuiteResults | Export-Csv -Path $suitesCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "CSV suites: $suitesCsvPath ($($allSuiteResults.Count) suites)" -Level "OK"
}

# CSV de Test Cases (si se incluyeron)
if ($allTestCaseResults.Count -gt 0) {
    $tcCsvPath = Join-Path $OutputDir "${baseFileName}_testcases.csv"
    $allTestCaseResults | Export-Csv -Path $tcCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "CSV test cases: $tcCsvPath ($($allTestCaseResults.Count) test cases)" -Level "OK"
}

# JSON consolidado
$jsonPath = Join-Path $OutputDir "${baseFileName}.json"
$totalPlans = ($projectSummaries | Measure-Object -Property TestPlanCount -Sum).Sum
$totalActivePlans = ($projectSummaries | Measure-Object -Property ActivePlans -Sum).Sum
$totalInactivePlans = ($projectSummaries | Measure-Object -Property InactivePlans -Sum).Sum
$totalSuites = ($projectSummaries | Measure-Object -Property TotalSuites -Sum).Sum
$totalTestCases = ($projectSummaries | Measure-Object -Property TotalTestCases -Sum).Sum
$totalTestPoints = ($projectSummaries | Measure-Object -Property TotalTestPoints -Sum).Sum
$projectsWithPlans = @($projectSummaries | Where-Object { $_.TestPlanCount -gt 0 }).Count
$projectsWithErrors = @($projectSummaries | Where-Object { $_.Status -eq "ERROR" }).Count

$jsonReport = [PSCustomObject]@{
    AuditDate             = (Get-Date -Format "o")
    Collection            = $AdoBaseUrl
    TotalProjectsAnalyzed = $totalProjects
    ProjectsWithTestPlans = $projectsWithPlans
    ProjectsWithErrors    = $projectsWithErrors
    TotalTestPlans        = $totalPlans
    ActivePlans           = $totalActivePlans
    InactivePlans         = $totalInactivePlans
    TotalSuites           = $totalSuites
    TotalTestCases        = $totalTestCases
    TotalTestPoints       = $totalTestPoints
    IncludeTestCases      = $IncludeTestCases
    ProjectSummaries      = $projectSummaries
    TestPlans             = $allTestPlanResults
}

$jsonReport | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Status "JSON consolidado: $jsonPath" -Level "OK"

# ----------------------------------------------------------------
# Resumen en consola
# ----------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     RESUMEN - Inventario de Test Plans" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Collection:              $AdoBaseUrl" -ForegroundColor White
Write-Host "  Proyectos analizados:    $totalProjects" -ForegroundColor White
Write-Host "  Proyectos con Test Plans: $projectsWithPlans" -ForegroundColor White
if ($projectsWithErrors -gt 0) {
    Write-Host "  Proyectos con ERROR:     $projectsWithErrors" -ForegroundColor Red
}
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  TOTAL TEST PLANS:        $totalPlans" -ForegroundColor Green
Write-Host "    Activos:               $totalActivePlans" -ForegroundColor Green
Write-Host "    Inactivos:             $totalInactivePlans" -ForegroundColor $(if ($totalInactivePlans -gt 0) { "Yellow" } else { "Green" })
Write-Host "  TOTAL SUITES:            $totalSuites" -ForegroundColor White
Write-Host "  TOTAL TEST CASES:        $totalTestCases" -ForegroundColor White
if ($IncludeTestCases) {
    Write-Host "  TOTAL TEST POINTS:       $totalTestPoints" -ForegroundColor White
}
Write-Host "================================================================" -ForegroundColor Cyan

# Top proyectos por cantidad de Test Plans
$topProjects = @($projectSummaries | Where-Object { $_.TestPlanCount -gt 0 } | Sort-Object -Property TestPlanCount -Descending | Select-Object -First 15)
if ($topProjects.Count -gt 0) {
    Write-Host ""
    Write-Status "Top proyectos por cantidad de Test Plans:" -Level "OK"
    $rank = 0
    foreach ($proj in $topProjects) {
        $rank++
        $planInfo = "$($proj.TestPlanCount) planes ($($proj.ActivePlans) activos)"
        $suiteInfo = "$($proj.TotalSuites) suites, $($proj.TotalTestCases) cases"
        Write-Host "  $rank. $($proj.Project): $planInfo | $suiteInfo" -ForegroundColor White
    }
}

# Proyectos con errores
$errorProjects = @($projectSummaries | Where-Object { $_.Status -eq "ERROR" })
if ($errorProjects.Count -gt 0) {
    Write-Host ""
    Write-Status "PROYECTOS CON ERROR:" -Level "ERROR"
    foreach ($ep in $errorProjects) {
        Write-Host "  - $($ep.Project): $($ep.ErrorDetail)" -ForegroundColor Red
    }
}

$totalElapsed = (Get-Date) - $globalStartTime
Write-Host ""
Write-Status "Inventario completado en $($totalElapsed.ToString('hh\:mm\:ss')). Reportes en: $OutputDir" -Level "OK"

# Cerrar log
if ($script:LogFilePath) {
    "" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "RESUMEN FINAL" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Projects Analyzed: $totalProjects" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Projects with Test Plans: $projectsWithPlans" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Total Test Plans: $totalPlans (Active: $totalActivePlans, Inactive: $totalInactivePlans)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Total Suites: $totalSuites" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Total Test Cases: $totalTestCases" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "Elapsed: $($totalElapsed.ToString('hh\:mm\:ss'))" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    "=" * 80 | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    Write-Status "Log guardado en: $script:LogFilePath" -Level "OK"
}
