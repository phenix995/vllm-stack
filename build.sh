#!/bin/bash

# Set error handling
set -e

echo "Starting vLLM build process..."

# Create a temporary directory for the build
BUILD_DIR=$(mktemp -d)
cd "$BUILD_DIR"

# Clone the vLLM repository
echo "Cloning vLLM repository..."
git clone https://github.com/vllm-project/vllm.git
cd vllm

# Build the Docker image with custom name
echo "Building Docker image as vllm-phenix..."
docker build -f Dockerfile -t vllm-phenix .

# Clean up
cd - > /dev/null
rm -rf "$BUILD_DIR"

echo "Build complete! You can now use the image 'vllm-phenix'" 