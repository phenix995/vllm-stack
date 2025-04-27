#!/bin/bash

# Script to launch vLLM Docker containers for a Ray cluster (head or worker)

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
EXPECTED_ARGS=4
if [ "$#" -lt ${EXPECTED_ARGS} ]; then
  echo "Usage: $0 <DOCKER_IMAGE> <HEAD_NODE_IP> <--head|--worker> <HOST_HF_HOME_PATH> [ADDITIONAL_DOCKER_ARGS...]"
  echo "Example (head): $0 vllm/vllm-openai:latest 192.168.1.100 --head /home/user/.cache/huggingface -e VLLM_HOST_IP=192.168.1.100"
  echo "Example (worker): $0 vllm/vllm-openai:latest 192.168.1.100 --worker /home/user/.cache/huggingface -e VLLM_HOST_IP=192.168.1.101"
  exit 1
fi

IMAGE="$1"
HEAD_IP="$2"
NODE_TYPE="$3"
HF_HOME_HOST="$4"
shift 4 # Remove the first 4 arguments, leaving any extra docker args in $@

# --- Basic Validation ---
if [ ! -d "${HF_HOME_HOST}" ]; then
    echo "Warning: Host Hugging Face home path does not exist: ${HF_HOME_HOST}"
    echo "Attempting to continue, but model downloads or access might fail if the directory isn't created by Docker."
    # Alternatively, exit here if the path must exist beforehand:
    # echo "Error: Host Hugging Face home path does not exist: ${HF_HOME_HOST}"
    # exit 1
fi

# --- Common Docker Options ---
# -it: Interactive TTY. Keeps the container attached to the shell. Use -d for detached mode.
# --rm: Remove container on exit.
# --gpus all: Make GPUs available. Ensure nvidia-container-toolkit is installed.
# --shm-size=1g: Recommended shared memory size for Ray.
# -v: Mount the host's Hugging Face cache directory into the container.
# -p 8265:8265: Expose Ray Dashboard port.
COMMON_DOCKER_OPTS=(
    "-it"
    "--rm"
    "--gpus" "all"
    "--shm-size=1g"
    "-v" "${HF_HOME_HOST}:/root/.cache/huggingface"
    "-p" "8265:8265"
)

# --- Node Specific Configuration ---
NODE_SPECIFIC_OPTS=()
RAY_COMMAND=""
CONTAINER_NAME=""

if [ "$NODE_TYPE" == "--head" ]; then
    echo "Configuring as HEAD node..."
    CONTAINER_NAME="head_node"
    # Expose Ray GCS port only on the head node
    NODE_SPECIFIC_OPTS+=("-p" "6379:6379")
    # Command to start Ray head node
    RAY_COMMAND="ray start --head --port=6379 --dashboard-host 0.0.0.0 --dashboard-port=8265 --block"

elif [ "$NODE_TYPE" == "--worker" ]; then
    echo "Configuring as WORKER node connecting to $HEAD_IP..."
    # Use a relatively unique name for worker nodes, though collisions are possible
    # if multiple workers are started on the *same host* without manual name changes.
    # Typically, one worker container runs per physical worker machine.
    CONTAINER_NAME="worker_node_$(hostname)_$(date +%s)"
    # Command to start Ray worker node connecting to the head
    RAY_COMMAND="ray start --address=${HEAD_IP}:6379 --block"

else
    echo "Error: Invalid node type specified: $NODE_TYPE. Must be --head or --worker."
    exit 1
fi

# Add container name to node specific options
NODE_SPECIFIC_OPTS+=("--name" "$CONTAINER_NAME")

# --- Construct and Run Docker Command ---
# Combine common options, node-specific options, any extra args ($@), the image, and the command
FULL_DOCKER_COMMAND=(
    "docker" "run"
    "${COMMON_DOCKER_OPTS[@]}"
    "${NODE_SPECIFIC_OPTS[@]}"
    "$@" # Pass through any additional arguments provided to the script
    "$IMAGE"
    $RAY_COMMAND # Needs to be unquoted to be treated as command + args by docker run
)

echo "--------------------------------------------------"
echo "Host HF Home: ${HF_HOME_HOST}"
echo "Mapped to Container HF Home: /root/.cache/huggingface"
echo "Head Node IP: ${HEAD_IP}"
echo "Node Type: ${NODE_TYPE}"
echo "Container Name: ${CONTAINER_NAME}"
echo "Using Image: ${IMAGE}"
if [ ${#@} -gt 0 ]; then
  echo "Additional Docker Args: $@"
fi
echo "--------------------------------------------------"
echo "Executing Docker Command:"
# Use printf for safer printing of command arguments
printf "%q " "${FULL_DOCKER_COMMAND[@]}"
echo # Newline after command
echo "--------------------------------------------------"

# Execute the command
"${FULL_DOCKER_COMMAND[@]}"

echo "--------------------------------------------------"
echo "Docker container exited."
echo "--------------------------------------------------"
