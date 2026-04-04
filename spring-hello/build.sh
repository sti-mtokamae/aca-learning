#!/bin/bash

echo "Building Spring Boot Hello API for ACA Learning..."

# Build the application
echo "1. Building with Maven..."
mvn clean package -DskipTests

# Check if build was successful
if [ $? -eq 0 ]; then
    echo "✅ Maven build successful"
else
    echo "❌ Maven build failed"
    exit 1
fi

# Build Docker image
echo "2. Building Docker image..."
docker build -t aca-hello-api:latest .

if [ $? -eq 0 ]; then
    echo "✅ Docker build successful"
else
    echo "❌ Docker build failed"
    exit 1
fi

echo "🎉 Build completed!"
echo ""
echo "To test locally:"
echo "  docker run -p 8080:8080 aca-hello-api:latest"
echo ""
echo "Test endpoints:"
echo "  http://localhost:8080/api/hello"
echo "  http://localhost:8080/api/hello/yourname"
echo "  http://localhost:8080/actuator/health"