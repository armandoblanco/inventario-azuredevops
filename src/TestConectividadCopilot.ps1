# ================================
# GitHub Copilot Connectivity Test
# ================================

$endpoints = @(
    "api.githubcopilot.com",
    "copilot-proxy.githubusercontent.com",
    "github.com",
    "githubusercontent.com"
)

Write-Host "==== DNS RESOLUTION TEST ====" -ForegroundColor Cyan
foreach ($endpoint in $endpoints) {
    try {
        $dns = Resolve-DnsName $endpoint -ErrorAction Stop
        Write-Host "[OK] DNS resolved for $endpoint" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] DNS failed for $endpoint" -ForegroundColor Red
    }
}

Write-Host "`n==== TCP CONNECTIVITY (PORT 443) ====" -ForegroundColor Cyan
foreach ($endpoint in $endpoints) {
    $test = Test-NetConnection -ComputerName $endpoint -Port 443
    if ($test.TcpTestSucceeded) {
        Write-Host "[OK] TCP 443 reachable for $endpoint" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] TCP 443 blocked for $endpoint" -ForegroundColor Red
    }
}

Write-Host "`n==== HTTPS REQUEST TEST ====" -ForegroundColor Cyan
foreach ($endpoint in $endpoints) {
    try {
        $response = Invoke-WebRequest -Uri "https://$endpoint" -UseBasicParsing -TimeoutSec 10
        Write-Host "[OK] HTTPS reachable for $endpoint (Status: $($response.StatusCode))" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] HTTPS failed for $endpoint" -ForegroundColor Red
        Write-Host "       Error: $($_.Exception.Message)"
    }
}

Write-Host "`n==== TLS VERSION CHECK ====" -ForegroundColor Cyan
try {
    [Net.ServicePointManager]::SecurityProtocol
    Write-Host "Current TLS settings checked." -ForegroundColor Yellow
} catch {
    Write-Host "TLS check failed." -ForegroundColor Red
}

Write-Host "`n==== PROXY CONFIG ====" -ForegroundColor Cyan
netsh winhttp show proxy

Write-Host "`n==== TEST COMPLETED ====" -ForegroundColor Cyan
