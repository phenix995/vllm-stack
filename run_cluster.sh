#!/bin/bash

# Script to launch vLLM Docker containers for a Ray cluster (head or worker)

set -e # Exit immediately if a command exits with a non-zero status.

# --- Source .env file ---
# Load configuration variables from .env file if it exists
# Variables in .env can be overridden by command-line arguments
ENV_FILE=".env"
if [ -f "$ENV_FILE" ]; then
  echo "Sourcing configuration from $ENV_FILE..."
  # Use set -a to export variables, making them available to sub-processes if needed,
  # though we primarily use them within this script. Use set +a afterwards.
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "No .env file found, relying solely on command-line arguments and script defaults."
fi

# --- Configuration & Argument Parsing ---
# Usage message function
usage() {
  echo "Usage: $0 [--head|--worker] [DOCKER_IMAGE] [HEAD_NODE_IP] [HOST_HF_HOME_PATH] [ADDITIONAL_DOCKER_ARGS...]"
  echo ""
  echo "Arguments:"
  echo "  --head | --worker       Specify whether to run as head or worker node. If omitted, you will be prompted."
  echo "  DOCKER_IMAGE            (Optional) Docker image to use. Defaults to DEFAULT_DOCKER_IMAGE in .env or script default."
  echo "  HEAD_NODE_IP            (Optional) IP address of the head node. Required for worker nodes. Defaults to DEFAULT_HEAD_NODE_IP in .env."
  echo "  HOST_HF_HOME_PATH       (Optional) Path to host's Hugging Face cache. Defaults to DEFAULT_HOST_HF_HOME_PATH in .env or \$HOME/.cache/huggingface."
  echo "  ADDITIONAL_DOCKER_ARGS  (Optional) Any additional arguments to pass to 'docker run'."
  echo ""
  echo "Configuration can be provided via .env file or command-line arguments."
  echo "Command-line arguments override values set in .env."
  echo "See .env file for additional configuration like HEAD_NODE_EXTRA_ENV_VARS."
  echo ""
  echo "Example (head, using .env defaults): $0 --head"
  echo "Example (head, prompting for type): $0"
  echo "Example (head, overriding image): $0 --head my/custom-vllm-image"
  echo "Example (worker, specifying head IP): $0 --worker vllm/vllm-openai:latest 192.168.1.100 /home/user/.cache/huggingface"
  echo "Example (worker, using .env defaults, providing extra docker arg): $0 --worker -- -e VLLM_HOST_IP=192.168.1.101"
  exit 1
}

# --- Default values (used if not set in .env or command line) ---
# Set defaults here only if they weren't potentially set by sourcing .env
DEFAULT_DOCKER_IMAGE="${DEFAULT_DOCKER_IMAGE:-vllm/vllm-openai:latest}"
DEFAULT_HEAD_NODE_IP="${DEFAULT_HEAD_NODE_IP:-}"
DEFAULT_HOST_HF_HOME_PATH="${DEFAULT_HOST_HF_HOME_PATH:-${HOME}/.cache/huggingface}"
DEFAULT_ADDITIONAL_DOCKER_ARGS="${DEFAULT_ADDITIONAL_DOCKER_ARGS:-}"
HEAD_NODE_EXTRA_ENV_VARS="${HEAD_NODE_EXTRA_ENV_VARS:-}" # Read from .env or set to empty

# --- Determine Node Type (Prompt if necessary) ---
NODE_TYPE=""
ARGS_START_INDEX=1 # Where the remaining args (IMAGE, etc.) start

if [ "$#" -ge 1 ] && ( [ "$1" == "--head" ] || [ "$1" == "--worker" ] ); then
  NODE_TYPE="$1"
  shift # Consume the node type argument
  ARGS_START_INDEX=1 # Args now start at $1 again
else
  echo "Node type (--head or --worker) not specified as the first argument."
  while true; do
    read -p "Please enter node type (--head or --worker): " selected_type
    case "$selected_type" in
      --head|--worker )
        NODE_TYPE="$selected_type"
        break # Exit loop if valid type entered
        ;;
      * )
        echo "Invalid input. Please enter exactly '--head' or '--worker'."
        ;;
    esac
  done
  # Do not shift here, the remaining args are still $1, $2, ...
  ARGS_START_INDEX=1
fi

# --- Parse Remaining Command Line Arguments ---
# Use parameter expansion with offsets based on ARGS_START_INDEX
# Note: Bash arrays are 0-indexed, but positional parameters ($1, $2) are 1-indexed.
# We'll use temporary variables for clarity.

ARG1="${!ARGS_START_INDEX}"
ARG2="${@:ARGS_START_INDEX+1:1}" # Get the second arg (index ARGS_START_INDEX + 1)
ARG3="${@:ARGS_START_INDEX+2:1}" # Get the third arg (index ARGS_START_INDEX + 2)

IMAGE="${ARG1:-${DEFAULT_DOCKER_IMAGE}}"
HEAD_IP="${ARG2:-${DEFAULT_HEAD_NODE_IP}}"
HF_HOME_HOST="${ARG3:-${DEFAULT_HOST_HF_HOME_PATH}}"

# Handle additional docker args: Use command-line if provided, otherwise use default from .env
# Check if there are arguments beyond the first 3 (or fewer if some were omitted)
if [ "$#" -ge $((ARGS_START_INDEX + 3)) ]; then
  # Capture all arguments starting from the 4th position relative to ARGS_START_INDEX
  ADDITIONAL_DOCKER_ARGS=("${@:ARGS_START_INDEX+3}")
else
  # Convert string from default env var to array (handles spaces in args)
  read -r -a ADDITIONAL_DOCKER_ARGS <<< "${DEFAULT_ADDITIONAL_DOCKER_ARGS}"
fi


# --- Basic Validation ---
# NODE_TYPE is already validated by the input prompt or initial check

if [ -z "$IMAGE" ]; then
  echo "Error: Docker image must be specified via command line or DEFAULT_DOCKER_IMAGE in .env"
  usage
fi

if [ "$NODE_TYPE" == "--worker" ] && [ -z "$HEAD_IP" ]; then
  echo "Error: Head node IP must be specified via command line or DEFAULT_HEAD_NODE_IP in .env for worker nodes."
  usage
fi

if [ -z "$HF_HOME_HOST" ]; then
  echo "Error: Host Hugging Face home path must be specified via command line or DEFAULT_HOST_HF_HOME_PATH in .env"
  usage
fi

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
HEAD_ENV_VARS_ARRAY=() # For display purposes

if [ "$NODE_TYPE" == "--head" ]; then
    echo "Configuring as HEAD node..."
    CONTAINER_NAME="head_node"
    # Expose Ray GCS port only on the head node
    NODE_SPECIFIC_OPTS+=("-p" "6379:6379")

    # Add extra environment variables for the head node from .env
    if [ -n "$HEAD_NODE_EXTRA_ENV_VARS" ]; then
        echo "Adding extra head node environment variables: $HEAD_NODE_EXTRA_ENV_VARS"
        # Split the string by space and add each as -e VAR=VALUE
        read -r -a env_vars_array <<< "$HEAD_NODE_EXTRA_ENV_VARS"
        for env_var in "${env_vars_array[@]}"; do
            NODE_SPECIFIC_OPTS+=("-e" "$env_var")
            HEAD_ENV_VARS_ARRAY+=("$env_var") # Store for summary
        done
    fi

    # Command to start Ray head node
    RAY_COMMAND="ray start --head --port=6379 --dashboard-host 0.0.0.0 --dashboard-port=8265 --block"

elif [ "$NODE_TYPE" == "--worker" ]; then
    echo "Configuring as WORKER node connecting to $HEAD_IP..."
    # Use a relatively unique name for worker nodes
    CONTAINER_NAME="worker_node_$(hostname)_$(date +%s)"
    # Command to start Ray worker node connecting to the head
    RAY_COMMAND="ray start --address=${HEAD_IP}:6379 --block"

fi

# Add container name to node specific options
NODE_SPECIFIC_OPTS+=("--name" "$CONTAINER_NAME")

# --- Construct and Run Docker Command ---
# Combine common options, node-specific options, additional args, the image, and the command
FULL_DOCKER_COMMAND=(
    "docker" "run"
    "${COMMON_DOCKER_OPTS[@]}"
    "${NODE_SPECIFIC_OPTS[@]}"
    "${ADDITIONAL_DOCKER_ARGS[@]}" # Pass through additional arguments
    "$IMAGE"
    $RAY_COMMAND # Needs to be unquoted to be treated as command + args by docker run
)

echo "--------------------------------------------------"
echo "Configuration:"
echo "  Node Type: ${NODE_TYPE}"
echo "  Using Image: ${IMAGE}"
if [ "$NODE_TYPE" == "--worker" ]; then
  echo "  Head Node IP: ${HEAD_IP}"
fi
if [ "$NODE_TYPE" == "--head" ] && [ ${#HEAD_ENV_VARS_ARRAY[@]} -gt 0 ]; then
  echo "  Head Node Env Vars: ${HEAD_ENV_VARS_ARRAY[*]}"
fi
echo "  Host HF Home: ${HF_HOME_HOST}"
echo "  Mapped to Container HF Home: /root/.cache/huggingface"
echo "  Container Name: ${CONTAINER_NAME}"
if [ ${#ADDITIONAL_DOCKER_ARGS[@]} -gt 0 ]; then
  echo "  Additional Docker Args: ${ADDITIONAL_DOCKER_ARGS[*]}"
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

