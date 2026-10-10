# docker_wsl_compact_vdisk.ps1 - Docker cleanup, then compact the Docker and WSL distro virtual disks
param(
    [string]$LogPath = "C:\Logs\DockerCleanup.log",
    # WSL distros whose virtual disk is compacted along with Docker's (wildcards allowed)
    [string]$DistroName = "Ubuntu*"
)

$DockerDesktopExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
$DockerProcesses = @("Docker Desktop", "com.docker.backend", "com.docker.service")
$script:Warnings = 0

# Read docker's output as UTF-8 so its check marks are not garbled in the log.
# There is no console to configure in some scheduled-task sessions; that is fine.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Create log directory if it doesn't exist
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # Out-Host keeps the line out of the pipeline, so functions that log
    # still return only their own value
    "$timestamp - $Message" | Tee-Object -FilePath $LogPath -Append | Out-Host
}

function Write-Warn {
    param([string]$Message)
    $script:Warnings++
    Write-Log "WARNING: $Message"
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

    Write-Log "Docker did not become ready within $TimeoutSeconds seconds"
    return $false
}

function Stop-DockerDaemon {
    Write-Log "Gracefully stopping Docker daemon..."

    # Method 1: Try new Docker Desktop CLI command (if available)
    try {
        Write-Log "Attempting: docker desktop stop"
        docker desktop stop --timeout 30 2>&1 | Out-Null
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
        wsl -t docker-desktop 2>&1 | Out-Null
        Write-Log "Terminated docker-desktop distro"

        # Stop docker-desktop-data distro
        wsl -t docker-desktop-data 2>&1 | Out-Null
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

function Stop-DockerProcesses {
    foreach ($proc in $DockerProcesses) {
        Get-Process $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForFileRelease {
    param([string]$Path, [int]$TimeoutSeconds = 60)

    # A disk can stay locked for a while after WSL and Docker have stopped.
    # Opening it with no sharing succeeds only once nothing else holds it.
    $elapsed = 0
    while ($true) {
        try {
            $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
            $stream.Close()
            return $true
        } catch {
            if ($elapsed -ge $TimeoutSeconds) { return $false }
            Start-Sleep -Seconds 5
            $elapsed += 5
        }
    }
}

function Compact-Vhdx {
    param([string]$Label, [string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Warn "$Label VHDX not found at: $Path"
        return
    }
    if (-not (Wait-ForFileRelease -Path $Path)) {
        Write-Warn "$Label VHDX is still in use by another process after 60 seconds; trying anyway"
    }
    Write-Log "Compacting $Label VHDX at: $Path"
    $initialSize = (Get-Item $Path).Length / 1GB
    Write-Log "$Label initial size: $([math]::Round($initialSize, 2)) GB"

    # diskpart only compacts a disk that is detached or attached read-only.
    # Built as an array so the script file gets CRLF line endings whatever
    # line endings this .ps1 was saved with.
    $diskpartScript = @(
        "select vdisk file=`"$Path`"",
        "attach vdisk readonly",
        "compact vdisk",
        "detach vdisk",
        "exit"
    )
    $scriptPath = "$env:TEMP\compact_$($Label -replace '\W','').txt"
    $diskpartScript | Out-File -FilePath $scriptPath -Encoding ASCII
    # Log diskpart's messages one line each. Its progress lines repeat for
    # minutes, so those go to the console only, once per new percentage.
    $lastPercent = ""
    diskpart /s $scriptPath 2>&1 | ForEach-Object {
        $line = "$_".Trim()
        if ($line -match '^(\d+) percent completed$') {
            if ($Matches[1] -ne $lastPercent) {
                $lastPercent = $Matches[1]
                Write-Host "    ${Label}: $line"
            }
        } elseif ($line) {
            Write-Log "$Label diskpart: $line"
        }
    }
    $diskpartExit = $LASTEXITCODE
    Remove-Item $scriptPath -ErrorAction SilentlyContinue
    if ($diskpartExit -ne 0) {
        Write-Warn "$Label diskpart exited with code $diskpartExit"
    }

    Start-Sleep -Seconds 2
    $finalSize = (Get-Item $Path).Length / 1GB
    Write-Log "$Label final size: $([math]::Round($finalSize, 2)) GB  (reclaimed $([math]::Round($initialSize - $finalSize, 2)) GB)"
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
        Start-Process $DockerDesktopExe
        Start-Sleep -Seconds 15
    }

    # Wait for Docker to be ready. Nothing has been stopped yet, so it is safe to give up here.
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

    # [1] Stopped containers, unused networks, dangling images and build cache.
    # No -a on purpose: tagged images are kept even when no container uses them,
    # so they do not have to be rebuilt or pulled again.
    Write-Log "Running: docker system prune -f  (dangling images + build cache, NO -a)"
    docker system prune -f 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "docker system prune exited with code $LASTEXITCODE"
    }

    # [2] Anonymous volumes only (Docker names them with 64 hex characters).
    # Named volumes usually hold data someone chose to keep, so unused ones are
    # logged and left alone. Filtering by name gives the same result on every
    # Docker version; older versions of 'docker volume prune' removed named
    # volumes too.
    Write-Log "Pruning anonymous volumes only (named dangling volumes are preserved)..."
    $danglingVols = docker volume ls -q -f dangling=true 2>$null
    $removedVols = 0
    $skippedNamed = @()
    foreach ($v in $danglingVols) {
        if ($v -match '^[0-9a-f]{64}$') {
            docker volume rm $v 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $removedVols++ }
        } else {
            $skippedNamed += $v
        }
    }
    Write-Log "Removed $removedVols anonymous volume(s)."
    if ($skippedNamed.Count -gt 0) {
        Write-Log "SKIPPED $($skippedNamed.Count) NAMED dangling volume(s) (preserved, delete manually if unwanted): $($skippedNamed -join ', ')"
    }

    # Get post-cleanup usage
    $postCleanupUsage = docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}" 2>$null
    Write-Log "Post-cleanup usage: $postCleanupUsage"

    # PROPER DOCKER DAEMON SHUTDOWN
    if (-not (Stop-DockerDaemon)) {
        Write-Log "Docker daemon was not confirmed stopped; Docker Desktop process was force-stopped"
    }

    # Docker Desktop's background processes can keep its disk file open after
    # the daemon has stopped, which makes diskpart fail with "being used by
    # another process". They are started again by the restart step below.
    Write-Log "Stopping remaining Docker Desktop processes..."
    Stop-DockerProcesses

    # Now safely shutdown WSL (Docker daemon should already be stopped)
    Write-Log "Now safely shutting down WSL..."
    wsl --shutdown 2>&1 | Out-Null
    Start-Sleep -Seconds 5

    # Compact Docker's disk AND the WSL distro's disk. The distro's disk is the
    # one that grows from day-to-day work inside WSL, and it never shrinks on
    # its own. 'wsl --shutdown' above stopped every distro, so both are free.

    # Docker Desktop's data disk
    Compact-Vhdx -Label "Docker" -Path "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"

    # Distro disks: read each one's folder from the registry (no hard-coded GUID)
    $distros = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.DistributionName -like $DistroName })
    if ($distros.Count -eq 0) {
        Write-Warn "No WSL distro matching '$DistroName' found in the registry; skipping distro VHDX compaction."
    }
    foreach ($distro in $distros) {
        $distroBase = $distro.BasePath -replace '^\\\\\?\\',''
        $vhdFile = if ($distro.VhdFileName) { $distro.VhdFileName } else { 'ext4.vhdx' }
        Compact-Vhdx -Label $distro.DistributionName -Path (Join-Path $distroBase $vhdFile)
    }

    # Restart Docker Desktop using CLI command
    Write-Log "Starting Docker Desktop using CLI..."

    # Kill any lingering Docker processes first
    Stop-DockerProcesses
    Start-Sleep -Seconds 3

    # Try Docker CLI start command first (most reliable for scheduled tasks)
    $started = $false
    try {
        Write-Log "Attempting: docker desktop start"
        $startResult = docker desktop start 2>&1
        Write-Log "Docker CLI start result: $startResult"
        if ($LASTEXITCODE -eq 0) { $started = $true }
    } catch {
        Write-Log "Docker CLI start command failed or not available: $($_.Exception.Message)"
    }

    # Fallback: Launch Docker Desktop executable
    if (-not $started) {
        Write-Log "Fallback: Launching Docker Desktop.exe"
        if (Test-Path $DockerDesktopExe) {
            Start-Process $DockerDesktopExe -ErrorAction SilentlyContinue
            Write-Log "Docker Desktop.exe launch attempted"
        } else {
            Write-Log "ERROR: Docker Desktop not found at: $DockerDesktopExe"
        }
    }

    # Wait for Docker to start (with longer timeout for scheduled tasks)
    if (-not (Wait-ForDocker -TimeoutSeconds 180)) {
        Write-Log "ERROR: Docker did not come back after the cleanup. Start Docker Desktop by hand."
        exit 1
    }

    if ($script:Warnings -gt 0) {
        Write-Log "=== Docker Monthly Cleanup Completed with $($script:Warnings) warning(s) ==="
    } else {
        Write-Log "=== Docker Monthly Cleanup Completed Successfully ==="
    }

} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
