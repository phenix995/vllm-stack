#!/bin/bash

# Set error handling
set -e

echo "Starting vLLM deployment process..."

# Run the build script
echo "Running build script..."
./build.sh

# Ask user for container choice
echo "Please choose which container to launch:"
echo "1) Worker"
echo "2) Controller"
read -p "Enter your choice (1 or 2): " choice

# Launch the chosen container
case $choice in
    1)
        echo "Launching worker container..."
        docker compose -f docker-compose-worker.yml up -d worker
        ;;
    2)
        echo "Launching controller container..."
        docker compose -f docker-compose-controller.yml up -d controller
        ;;
    *)
        echo "Invalid choice. Please select 1 or 2."
        exit 1
        ;;
esac

echo "Container launched successfully!"
