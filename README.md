# Docker WSL Disk Cleanup & Compact Script

A PowerShell script for automated Docker maintenance on Windows with WSL2 backend. This script performs monthly Docker cleanup and virtual disk compaction to prevent disk space bloat and maintain optimal Docker performance.

## Overview

Docker Desktop with WSL2 backend can accumulate significant disk space over time due to:
- Unused containers, images, and build cache
- WSL2 virtual disk files that grow but never shrink automatically
- Dangling volumes and networks

This script automates the cleanup process and can reclaim **substantial disk space** (users typically see 20-140GB+ freed during initial runs).

## Features

- ✅ **Automated Docker cleanup** - Removes unused containers, images, networks, and build cache
- ✅ **WSL2 virtual disk compaction** - Shrinks Docker's virtual disk file to actual usage size  
- ✅ **Graceful Docker daemon shutdown** - Prevents "WSL distro terminated abruptly" errors
- ✅ **Comprehensive logging** - Detailed logs for monitoring and troubleshooting
- ✅ **Safe restart sequence** - Ensures Docker Desktop restarts cleanly after maintenance
- ✅ **Multiple fallback methods** - Handles different Docker Desktop versions and configurations
- ✅ **Production ready** - Designed for unattended monthly automation

## Prerequisites

- **Windows 10/11** with WSL2 enabled
- **Docker Desktop** with WSL2 backend
- **PowerShell 5.1** or later  
- **Administrator privileges** (required for diskpart operations)

## Installation

1. **Download the script** to your preferred location (e.g., `C:\Scripts\`)
2. **Create the log directory**:
