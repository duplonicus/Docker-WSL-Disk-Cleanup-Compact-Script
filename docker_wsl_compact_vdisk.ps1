# Docker_Monthly_Cleanup.ps1 - With Proper Docker Daemon Shutdown
param(
    [string]$LogPath = "C:\Logs\DockerCleanup.log"
)

# Create log directory if it doesn't exist
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $LogPath -Append
}

function Wait-ForDocker {
    param([int]$TimeoutSeconds = 120)
    
    Write-Log "Waiting for Docker to be ready..."
    $elapsed = 0
    do {
        Start-Sleep -Seconds 5
        $elapsed += 5
        try {
            $dockerStatus = docker version --format '{{.Server.Version}}' 2>$null
            if ($dockerStatus) {
                Write-Log "Docker is ready. Version: $dockerStatus"
                return $true
            }
        } catch {
            # Continue waiting
        }
    } while ($elapsed -lt $TimeoutSeconds)
    
    Write-Log "WARNING: Docker did not become ready within $TimeoutSeconds seconds"
    return $false
}

function Stop-DockerDaemon {
    Write-Log "Gracefully stopping Docker daemon..."
    
    # Method 1: Try new Docker Desktop CLI command (if available)
    try {
        Write-Log "Attempting: docker desktop stop"
        docker desktop stop --timeout 30 2>$null
        Start-Sleep -Seconds 5
        
        # Check if Docker daemon is stopped
        docker version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Docker daemon stopped successfully via CLI"
            return $true
        }
    } catch {
        Write-Log "Docker Desktop CLI stop not available, trying alternative methods..."
    }
    
    # Method 2: Stop specific Docker WSL distros
    try {
        Write-Log "Stopping Docker WSL distros..."

        # Stop docker-desktop distro
        wsl -t docker-desktop 2>$null
        Write-Log "Terminated docker-desktop distro"
        
        # Stop docker-desktop-data distro  
        wsl -t docker-desktop-data 2>$null
        Write-Log "Terminated docker-desktop-data distro"
        
        # Give it time to shut down
        Start-Sleep -Seconds 10
        
        # Verify Docker daemon is stopped
        docker version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Docker daemon stopped successfully via WSL termination"
            return $true
        }
    } catch {
        Write-Log "WSL termination method failed: $($_.Exception.Message)"
    }
    
    # Method 3: Force stop Docker Desktop process (fallback)
    Write-Log "Using fallback method: Force stopping Docker Desktop process"
    Get-Process "Docker Desktop" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 10
    
    return $false
}

try {
    Write-Log "=== Starting Docker Monthly Cleanup ==="
    
    # Check if running as Administrator
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Log "ERROR: Script must be run as Administrator"
        exit 1
    }

    # Ensure Docker Desktop is running first
    Write-Log "Starting Docker Desktop if not running..."
    $dockerProcess = Get-Process "Docker Desktop" -ErrorAction SilentlyContinue
    if (-not $dockerProcess) {
        Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        Start-Sleep -Seconds 15
    }

    # Wait for Docker to be ready
    if (-not (Wait-ForDocker)) {
        Write-Log "ERROR: Docker failed to start properly"
        exit 1
    }

    # Get initial disk usage
    Write-Log "Getting initial Docker disk usage..."
    $initialUsage = docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}" 2>$null
    Write-Log "Initial usage: $initialUsage"

    # Docker cleanup commands
    Write-Log "Starting Docker cleanup..."

    # Clean up unused containers, networks, images, and build cache
    Write-Log "Running: docker system prune -a -f"
    docker system prune -a -f 2>&1 | ForEach-Object { Write-Log $_ }

    # Get post-cleanup usage
    $postCleanupUsage = docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}" 2>$null
    Write-Log "Post-cleanup usage: $postCleanupUsage"

    # PROPER DOCKER DAEMON SHUTDOWN
    Stop-DockerDaemon
    
    # Now safely shutdown WSL (Docker daemon should already be stopped)
    Write-Log "Now safely shutting down WSL..."
    wsl --shutdown
    Start-Sleep -Seconds 5

    # Get Docker WSL disk path
    $dockerDiskPath = "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"
    
    if (Test-Path $dockerDiskPath) {
        Write-Log "Found Docker WSL disk at: $dockerDiskPath"
        
        # Get initial file size
        $initialSize = (Get-Item $dockerDiskPath).Length / 1GB
        Write-Log "Initial VHDX size: $([math]::Round($initialSize, 2)) GB"
        
        # Create diskpart script
        $diskpartScript = @"
select vdisk file="$dockerDiskPath"
compact vdisk
exit
"@
        
        $scriptPath = "$env:TEMP\compact_docker.txt"
        $diskpartScript | Out-File -FilePath $scriptPath -Encoding ASCII
        
        Write-Log "Running diskpart compact..."
        $diskpartResult = diskpart /s $scriptPath 2>&1
        Write-Log "Diskpart output: $diskpartResult"
        
        # Clean up script file
        Remove-Item $scriptPath -ErrorAction SilentlyContinue
        
        # Get final file size
        Start-Sleep -Seconds 2
        $finalSize = (Get-Item $dockerDiskPath).Length / 1GB
        $savedSpace = $initialSize - $finalSize
        Write-Log "Final VHDX size: $([math]::Round($finalSize, 2)) GB"
        Write-Log "Space reclaimed: $([math]::Round($savedSpace, 2)) GB"
        
    } else {
        Write-Log "WARNING: Docker WSL disk not found at: $dockerDiskPath"
    }

    # Restart Docker Desktop with proper settings for scheduled tasks
    Write-Log "Starting Docker Desktop..."

    # Start Docker Desktop using full path with proper arguments
    $dockerPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerPath) {
        # Use PowerShell job to launch in background with proper context
        Start-Job -ScriptBlock {
            param($path)
            & $path
        } -ArgumentList $dockerPath | Out-Null

        Write-Log "Docker Desktop launch command issued"
    } else {
        Write-Log "WARNING: Docker Desktop not found at: $dockerPath"
    }

    # Wait for Docker to start (with longer timeout for scheduled tasks)
    Wait-ForDocker -TimeoutSeconds 180

    Write-Log "=== Docker Monthly Cleanup Completed Successfully ==="

} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
