#!/bin/bash

# Create a temporary directory for the build
BUILD_DIR=$(mktemp -d)
cd "$BUILD_DIR"

# Download the Dockerfile from vLLM's repository
echo "Downloading Dockerfile from vLLM repository..."
curl -O https://raw.githubusercontent.com/vllm-project/vllm/main/Dockerfile

# Build the Docker image with custom name
echo "Building Docker image as vllm-phenix..."
docker build -t vllm-phenix .

# Clean up
cd - > /dev/null
rm -rf "$BUILD_DIR"

echo "Build complete! You can now use the image 'vllm-phenix'" 