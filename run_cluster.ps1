<#
.SYNOPSIS
Script to launch vLLM Docker containers for a Ray cluster (head or worker) on Windows.

.DESCRIPTION
This PowerShell script configures and runs a Docker container for either a Ray head node or a Ray worker node.
It reads default configuration from a .env file in the same directory, but command-line arguments take precedence.
If the node type is not specified as the first argument, the script will prompt for it.
It requires Docker Desktop for Windows to be installed and running.

.PARAMETER NodeType
(Optional, Position=0) Specify whether to run as '--head' or '--worker' node. If omitted, you will be prompted.

.PARAMETER DockerImage
(Optional, Position=1) Docker image to use. Defaults to value in .env or 'vllm/vllm-openai:latest'.

.PARAMETER HeadNodeIP
(Optional, Position=2) IP address of the head node. Required for worker nodes if not set in .env.

.PARAMETER HostHFHomePath
(Optional, Position=3) Path to the host's Hugging Face cache directory. Defaults to value in .env or '$env:USERPROFILE\.cache\huggingface'.

.PARAMETER AdditionalDockerArgs
(Optional) Any additional arguments to pass directly to 'docker run'. Must be passed after all other positional arguments.

.EXAMPLE
# Run as head node using .env defaults (will prompt for node type if --head is omitted)
.\run_cluster.ps1 --head
.\run_cluster.ps1

.EXAMPLE
# Run as head node, overriding the image
.\run_cluster.ps1 --head my/custom-vllm-image

.EXAMPLE
# Run as worker node, specifying head IP and using default image/path
.\run_cluster.ps1 --worker --HeadNodeIP 192.168.1.100

.EXAMPLE
# Run as worker node, specifying all parameters positionally (after type)
.\run_cluster.ps1 --worker vllm/vllm-openai:latest 192.168.1.100 C:\Users\Me\.cache\huggingface

.EXAMPLE
# Run as worker node, using .env defaults, providing extra docker args
.\run_cluster.ps1 --worker --AdditionalDockerArgs "-e", "VLLM_HOST_IP=192.168.1.101", "--env", "NVIDIA_DRIVER_CAPABILITIES=all"

.NOTES
- Requires Docker Desktop for Windows.
- Assumes PowerShell 5.1 or later.
- May require adjusting PowerShell execution policy (e.g., Set-ExecutionPolicy RemoteSigned -Scope CurrentUser).
- Path conversion for volume mounts assumes Docker Desktop handles standard Windows paths (e.g., C:/Users/...). If you encounter issues, you might need to adjust the Convert-WindowsPathToDockerMount function for WSL-style paths (e.g., /mnt/c/Users/...).
- Head node specific environment variables can be set via HEAD_NODE_EXTRA_ENV_VARS in .env (e.g., "CUDA_DEVICE_ORDER=PCI_BUS_ID").
#>
param(
    [Parameter(Mandatory=$false, Position=0)] # Changed Mandatory to $false
    [ValidateSet('--head', '--worker')]
    [string]$NodeType,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$DockerImage,

    [Parameter(Mandatory=$false, Position=2)]
    [string]$HeadNodeIP,

    [Parameter(Mandatory=$false, Position=3)]
    [string]$HostHFHomePath,

    [Parameter(Mandatory=$false, ValueFromRemainingArguments=$true)]
    [string[]]$AdditionalDockerArgs
)

# --- Script Settings ---
$ErrorActionPreference = 'Stop' # Exit script on error, similar to set -e

# --- Helper Function for Path Conversion ---
function Convert-WindowsPathToDockerMount {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WindowsPath
    )
    # Replace backslashes with forward slashes
    $DockerPath = $WindowsPath -replace '\\', '/'
    # Docker Desktop often handles C:/... paths directly.
    # If issues occur, especially with WSL 2 backend, you might need:
    # if ($DockerPath -match '^([A-Za-z]):') {
    #     $driveLetter = $Matches[1].ToLower()
    #     $DockerPath = $DockerPath -replace "^([A-Za-z]):", "/mnt/$driveLetter" # WSL 2 style path
    # }
    return $DockerPath
}


# --- Source .env file ---
$EnvFile = Join-Path $PSScriptRoot ".env"
$envVars = @{} # Store variables loaded from .env

if (Test-Path $EnvFile) {
    Write-Host "Sourcing configuration from $EnvFile..."
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        # Skip comments and empty lines
        if ($line -and !$line.StartsWith("#")) {
            $parts = $line -split '=', 2
            if ($parts.Length -eq 2) {
                $name = $parts[0].Trim()
                $value = $parts[1].Trim().Trim('"').Trim("'") # Remove potential quotes
                # Store in our hash table
                $envVars[$name] = $value
                # Optionally set as process environment variables if needed by sub-processes
                # [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
            }
        }
    }
} else {
    Write-Host "No .env file found, relying solely on command-line arguments and script defaults."
}

# --- Determine Node Type (Prompt if necessary) ---
# Check if NodeType parameter was bound (provided by user)
if (-not $PSBoundParameters.ContainsKey('NodeType')) {
    Write-Host "Node type (--head or --worker) was not specified."
    while ($true) {
        $selectedType = Read-Host "Please enter node type (--head or --worker)"
        if ($selectedType -eq '--head' -or $selectedType -eq '--worker') {
            $NodeType = $selectedType # Assign the valid input
            break # Exit loop
        } else {
            Write-Warning "Invalid input. Please enter exactly '--head' or '--worker'."
        }
    }
}
# If NodeType was provided, ValidateSet in param block handles validation.

# --- Configuration & Default Values ---
# Priority: Command-line arg > .env file > Script default

# Note: $DockerImage, $HeadNodeIP, $HostHFHomePath are already populated from bound parameters if provided.
# We only apply defaults if the parameter was NOT provided OR if it was provided but is empty/whitespace.

$FinalImage = if ($PSBoundParameters.ContainsKey('DockerImage') -and -not [string]::IsNullOrWhiteSpace($DockerImage)) { $DockerImage } else { $envVars['DEFAULT_DOCKER_IMAGE'] }
if ([string]::IsNullOrWhiteSpace($FinalImage)) { $FinalImage = "vllm/vllm-openai:latest" } # Script default

$FinalHeadIP = if ($PSBoundParameters.ContainsKey('HeadNodeIP') -and -not [string]::IsNullOrWhiteSpace($HeadNodeIP)) { $HeadNodeIP } else { $envVars['DEFAULT_HEAD_NODE_IP'] }
# No script default for Head IP, validation later

$FinalHFHomeHost = if ($PSBoundParameters.ContainsKey('HostHFHomePath') -and -not [string]::IsNullOrWhiteSpace($HostHFHomePath)) { $HostHFHomePath } else { $envVars['DEFAULT_HOST_HF_HOME_PATH'] }
if ([string]::IsNullOrWhiteSpace($FinalHFHomeHost)) { $FinalHFHomeHost = Join-Path $env:USERPROFILE ".cache\huggingface" } # Script default

# Handle AdditionalDockerArgs - use command line if provided, else use .env default
$FinalAdditionalDockerArgs = if ($PSBoundParameters.ContainsKey('AdditionalDockerArgs')) { $AdditionalDockerArgs } else { $envVars['DEFAULT_ADDITIONAL_DOCKER_ARGS'] -split ' ' | Where-Object {$_} } # Split string from env var, filter empty
if ($null -eq $FinalAdditionalDockerArgs) { $FinalAdditionalDockerArgs = @() } # Ensure it's an empty array if null

# Get Head Node specific env vars from .env
$HeadNodeExtraEnvVarsString = $envVars['HEAD_NODE_EXTRA_ENV_VARS']
$HeadNodeExtraEnvVarsArray = @() # For adding to docker command
if (-not [string]::IsNullOrWhiteSpace($HeadNodeExtraEnvVarsString)) {
    $HeadNodeExtraEnvVarsArray = $HeadNodeExtraEnvVarsString -split ' ' | Where-Object {$_}
}


# --- Basic Validation ---
# NodeType is already validated

if ([string]::IsNullOrWhiteSpace($FinalImage)) {
    Write-Error "Docker image must be specified via command line or DEFAULT_DOCKER_IMAGE in .env"
    exit 1
}

if ($NodeType -eq "--worker" -and [string]::IsNullOrWhiteSpace($FinalHeadIP)) {
    Write-Error "Head node IP must be specified via command line or DEFAULT_HEAD_NODE_IP in .env for worker nodes."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($FinalHFHomeHost)) {
    Write-Error "Host Hugging Face home path must be specified via command line or DEFAULT_HOST_HF_HOME_PATH in .env"
    exit 1
}

if (-not (Test-Path $FinalHFHomeHost -PathType Container)) {
    Write-Warning "Host Hugging Face home path does not exist: $FinalHFHomeHost"
    Write-Warning "Attempting to continue, but model downloads or access might fail if the directory isn't created by Docker."
    # Alternatively, exit here:
    # Write-Error "Host Hugging Face home path does not exist: $FinalHFHomeHost"
    # exit 1
}

# Convert HF Home path for Docker mount
$DockerHFHomeHost = Convert-WindowsPathToDockerMount -WindowsPath $FinalHFHomeHost
$ContainerHFHome = "/root/.cache/huggingface" # Standard path inside vLLM container

# --- Common Docker Options ---
$CommonDockerOpts = @(
    "-it" # Interactive TTY. Use -d for detached. Consider making this an option.
    "--rm" # Remove container on exit.
    "--gpus", "all" # Make GPUs available. Requires nvidia-container-toolkit support in Docker Desktop.
    "--shm-size=1g" # Recommended shared memory size for Ray.
    "-v", "${DockerHFHomeHost}:${ContainerHFHome}" # Mount HF cache
    "-p", "8265:8265" # Expose Ray Dashboard port.
)

# --- Node Specific Configuration ---
$NodeSpecificOpts = @()
$RayCommand = ""
$ContainerName = ""
$HeadEnvVarsForDisplay = @() # For summary output

if ($NodeType -eq "--head") {
    Write-Host "Configuring as HEAD node..."
    $ContainerName = "head_node"
    # Expose Ray GCS port only on the head node
    $NodeSpecificOpts += "-p", "6379:6379"

    # Add extra environment variables for the head node from .env
    if ($HeadNodeExtraEnvVarsArray.Count -gt 0) {
        Write-Host "Adding extra head node environment variables: $($HeadNodeExtraEnvVarsArray -join ' ')"
        foreach ($envVar in $HeadNodeExtraEnvVarsArray) {
            $NodeSpecificOpts += "-e", $envVar
            $HeadEnvVarsForDisplay += $envVar # Store for summary
        }
    }

    # Command to start Ray head node
    $RayCommand = "ray start --head --port=6379 --dashboard-host 0.0.0.0 --dashboard-port=8265 --block"

} elseif ($NodeType -eq "--worker") {
    Write-Host "Configuring as WORKER node connecting to $FinalHeadIP..."
    # Use a relatively unique name for worker nodes
    $Timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $ContainerName = "worker_node_${env:COMPUTERNAME}_${Timestamp}"
    # Command to start Ray worker node connecting to the head
    $RayCommand = "ray start --address=${FinalHeadIP}:6379 --block"
}

# Add container name to node specific options
$NodeSpecificOpts += "--name", $ContainerName

# --- Construct and Run Docker Command ---
# Combine all parts into an argument list for docker run
$DockerArgs = @(
    "run"
    $CommonDockerOpts
    $NodeSpecificOpts
    $FinalAdditionalDockerArgs # Splat the array of additional args
    $FinalImage
    # Ray command needs to be passed as separate arguments to docker run
    $RayCommand.Split(' ') | Where-Object {$_}
)

Write-Host "--------------------------------------------------"
Write-Host "Configuration:"
Write-Host "  Node Type: $NodeType"
Write-Host "  Using Image: $FinalImage"
if ($NodeType -eq "--worker") {
  Write-Host "  Head Node IP: $FinalHeadIP"
}
if ($NodeType -eq "--head" -and $HeadEnvVarsForDisplay.Count -gt 0) {
  Write-Host "  Head Node Env Vars: $($HeadEnvVarsForDisplay -join ' ')"
}
Write-Host "  Host HF Home: $FinalHFHomeHost"
Write-Host "  Mapped to Container HF Home: $ContainerHFHome (Docker Path: $DockerHFHomeHost)"
Write-Host "  Container Name: $ContainerName"
if ($FinalAdditionalDockerArgs.Count -gt 0) {
  Write-Host "  Additional Docker Args: $($FinalAdditionalDockerArgs -join ' ')"
}
Write-Host "--------------------------------------------------"
Write-Host "Executing Docker Command:"
# Safely print the command arguments
$CommandString = "docker $($DockerArgs -join ' ')"
Write-Host $CommandString
Write-Host "--------------------------------------------------"

# Execute the command
try {
    # Use Start-Process if you need more control, or invoke directly
    & docker @DockerArgs
} catch {
    Write-Error "Docker command failed:"
    Write-Error $_
    # Exit with a non-zero status code
    exit 1
} finally {
    Write-Host "--------------------------------------------------"
    # Check the exit code of the last command (docker)
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Docker container exited with code: $LASTEXITCODE"
    } else {
        Write-Host "Docker container exited successfully."
    }
    Write-Host "--------------------------------------------------"
}

