#!/bin/sh
set -e

echo "======================================================"
echo "           Lenny Universal Installer"
echo "   (Linux, macOS, Cloud, Bare Metal, WSL2)"
echo "======================================================"

# -------------------------------------------------------
# 1. Detect OS + special environments
# -------------------------------------------------------

OS_TYPE="$(uname -s)"

detect_env="unknown"

case "$OS_TYPE" in
    Linux*)  
        OS="linux"

        # Detect WSL
        if grep -qi microsoft /proc/version 2>/dev/null; then
            detect_env="wsl"
        elif hostnamectl | grep -qi "Chassis: desktop"; then
            detect_env="local"
        elif hostnamectl | grep -qi "Chassis: laptop"; then
            detect_env="local"
        else
            detect_env="cloud"
        fi
        ;;
    Darwin*) 
        OS="mac"
        detect_env="local"
        ;;
    *)        
        echo "[!] Unsupported OS: $OS_TYPE"
        exit 1 
        ;;
esac

echo "[+] OS: $OS"
echo "[+] Environment: $detect_env"

# -------------------------------------------------------
# 2. Check and install dependencies
# -------------------------------------------------------

require() {
    command -v "$1" >/dev/null 2>&1
}

if [ "$OS" = "linux" ]; then
    echo "[+] Updating package index..."
    sudo apt update -y

    if ! require make; then
        echo "[+] Installing build-essential..."
        sudo apt install -y build-essential
    fi

    if ! require curl; then
        echo "[+] Installing curl..."
        sudo apt install -y curl
    fi
fi

# -------------------------------------------------------
# 3. Detect Docker or install it
# -------------------------------------------------------

docker_ready=false

if require docker; then
    echo "[+] Docker already installed."
    docker_ready=true
else
    echo "[+] Docker not found. Installing..."

    if [ "$OS" = "mac" ]; then
        # macOS uses Docker Desktop
        if ! require brew; then
            echo "[+] Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi

        echo "[+] Installing Docker Desktop..."
        brew install --cask docker
        open -a Docker
        echo "[+] Waiting for Docker Desktop to start..."
        sleep 20
        docker_ready=true

    else
        # Linux
        if [ "$detect_env" = "wsl" ]; then
            echo "[!] WSL detected — Docker Desktop for Windows is required."
            echo "    Enable: 'Use the WSL 2 based engine'"
            echo "    Then run this installer again."
            exit 1
        else
            echo "[+] Installing Docker engine..."
            curl -fsSL https://get.docker.com | sh

            echo "[+] Enabling Docker service..."
            sudo systemctl enable docker
            sudo systemctl start docker

            echo "[+] Adding user '$USER' to docker group..."
            sudo usermod -aG docker "$USER"
        fi
    fi
fi

# -------------------------------------------------------
# 4. Wait for Docker to fully start
# -------------------------------------------------------

i=1
while [ $i -le 10 ]; do
    if docker info >/dev/null 2>&1; then
        echo "[✓] Docker is ready."
        break
    fi
    echo "Waiting for Docker ($i/10)..."
    sleep 6
    i=$((i+1))
done

if [ $i -eq 11 ]; then
    echo "[!] Docker failed to start."
    exit 1
fi

# -------------------------------------------------------
# 5. Download Lenny repo
# -------------------------------------------------------

if [ ! -d "lenny" ]; then
    echo "[+] Downloading Lenny source code..."
    mkdir -p lenny
    curl -L https://github.com/ArchiveLabs/lenny/archive/refs/heads/main.tar.gz \
        | tar -xz --strip-components=1 -C lenny
    echo "[✓] Lenny source downloaded."
fi

# -------------------------------------------------------
# 6. Finish: Require logout for permissions
# -------------------------------------------------------

echo ""
echo "======================================================"
echo " Lenny is now installed."
echo ""
echo " IMPORTANT: You MUST log out and log back in"
echo "            so Docker permissions are applied."
echo ""
echo " Then run:"
echo "      cd lenny"
echo "      make start preload"
echo ""
echo "======================================================"
echo ""

exit 0
