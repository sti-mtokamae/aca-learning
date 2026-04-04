# ACA Learning - PowerShell版 デプロイスクリプト

Write-Host "🚀 Building Spring Boot Hello API..." -ForegroundColor Green

# Maven ビルド
Write-Host "1. Building with Maven..." -ForegroundColor Yellow
mvn clean package -DskipTests

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Maven build successful" -ForegroundColor Green
} else {
    Write-Host "❌ Maven build failed" -ForegroundColor Red
    exit 1
}

# Docker イメージビルド  
Write-Host "2. Building Docker image..." -ForegroundColor Yellow
docker build -t aca-hello-api:latest .

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Docker build successful" -ForegroundColor Green
} else {
    Write-Host "❌ Docker build failed" -ForegroundColor Red
    exit 1
}

Write-Host "🎉 Build completed!" -ForegroundColor Green
Write-Host ""
Write-Host "To test locally:" -ForegroundColor Cyan
Write-Host "  docker run -p 8080:8080 aca-hello-api:latest" -ForegroundColor Yellow
Write-Host ""
Write-Host "Test endpoints:" -ForegroundColor Cyan
Write-Host "  http://localhost:8080/api/hello" -ForegroundColor Yellow
Write-Host "  http://localhost:8080/api/hello/yourname" -ForegroundColor Yellow  
Write-Host "  http://localhost:8080/actuator/health" -ForegroundColor Yellow