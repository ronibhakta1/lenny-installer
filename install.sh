#!/bin/sh
set -e

# -------------------------------------------------------
# Lenny Universal Installer (improved)
# - Do NOT run as root. Script uses sudo only where required.
# - Ensures lenny/ is user-owned so .env etc can be created.
# - Installs build-essential, curl, docker (if missing).
# - Adds user to docker group (you must log out + back in).
# - Creates safe .env and reader.env if missing (with sensible defaults).
# -------------------------------------------------------

# refuse to run as root (prevents root-owned files)
if [ "$(id -u)" -eq 0 ]; then
  echo "[!] This installer must NOT be run as root."
  echo "    Run it as your normal user (e.g. lennyuser), not with sudo."
  exit 1
fi

USER_NAME="$(id -un)"
HOME_DIR="${HOME:-/home/$USER_NAME}"

echo "======================================================"
echo "           Lenny Universal Installer"
echo "   (Linux, macOS, Cloud, Bare Metal, WSL2)"
echo "======================================================"
echo "Running as user: $USER_NAME"
echo

# -------------------------
# 1) Detect OS + environment
# -------------------------
OS_TYPE="$(uname -s 2>/dev/null || echo Unknown)"
detect_env="unknown"
case "$OS_TYPE" in
  Linux*)
    OS="linux"
    if grep -qi microsoft /proc/version 2>/dev/null; then
      detect_env="wsl"
    else
      # try chassis via hostnamectl if available; fallback to 'local'
      if command -v hostnamectl >/dev/null 2>&1 && hostnamectl | grep -qi "Chassis:"; then
        if hostnamectl | grep -qi "Chassis: desktop\|Chassis: laptop"; then
          detect_env="local"
        else
          detect_env="cloud"
        fi
      else
        detect_env="local"
      fi
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

echo "[+] OS: $OS  env: $detect_env"
echo

# -------------------------
# helper: command exists
# -------------------------
require() {
  command -v "$1" >/dev/null 2>&1
}

# -------------------------
# 2) Ensure basic tools (Linux)
# -------------------------
if [ "$OS" = "linux" ]; then
  echo "[+] Updating package index (apt)..."
  sudo apt update -y

  if ! require make; then
    echo "[+] Installing build-essential (make, gcc, etc.)..."
    sudo apt install -y build-essential
  fi

  if ! require curl; then
    echo "[+] Installing curl..."
    sudo apt install -y curl
  fi
fi

# -------------------------
# 3) Ensure project dir exists and is owned by user
# -------------------------
PROJECT_DIR="$HOME_DIR/lenny"
if [ ! -d "$PROJECT_DIR" ]; then
  echo "[+] Creating project dir: $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"
fi

# Make sure user owns the project dir (fixes earlier permission problems)
echo "[+] Ensuring $PROJECT_DIR is owned by $USER_NAME"
sudo chown -R "$USER_NAME":"$USER_NAME" "$PROJECT_DIR"

# -------------------------
# 4) Install Docker if required
# -------------------------
if require docker; then
  echo "[+] Docker found."
else
  echo "[+] Docker not found; installing..."
  if [ "$OS" = "mac" ]; then
    if ! require brew; then
      echo "[+] Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    echo "[+] Installing Docker Desktop (via Homebrew)..."
    brew install --cask docker
    echo "[+] Starting Docker Desktop (please finish any GUI prompts)..."
    open -a Docker || true
    echo "[+] Waiting 20s for Docker Desktop..."
    sleep 20
  else
    # Linux path
    if [ "$detect_env" = "wsl" ]; then
      echo "[!] WSL detected — please install Docker Desktop for Windows and enable WSL integration."
      echo "    After that re-run this installer inside your WSL shell."
      exit 1
    fi

    echo "[+] Installing Docker engine via get.docker.com..."
    curl -fsSL https://get.docker.com | sh

    echo "[+] Enabling and starting docker service..."
    sudo systemctl enable docker || true
    sudo systemctl start docker || true

    echo "[+] Adding $USER_NAME to docker group (so you can run docker without sudo)..."
    sudo usermod -aG docker "$USER_NAME" || true
  fi
fi

# -------------------------
# 5) Wait for docker to be responsive
# -------------------------
echo "[+] Waiting for Docker to be ready (up to ~60s)..."
i=1
while [ $i -le 10 ]; do
  if docker info >/dev/null 2>&1; then
    echo "[✓] Docker is ready."
    break
  fi
  echo "    Docker not ready yet ($i/10)..."
  sleep 6
  i=$((i+1))
done

if [ $i -gt 10 ]; then
  echo "[!] Docker did not become ready. If you were just added to the docker group you must log out and log in again."
  echo "    After re-login run:"
  echo "      cd $PROJECT_DIR && make start preload"
  exit 1
fi

# -------------------------
# 6) Download Lenny repo into project dir if missing
# -------------------------
if [ ! -f "$PROJECT_DIR/Makefile" ]; then
  echo "[+] Downloading Lenny into $PROJECT_DIR ..."
  tmp_tar="$(mktemp -u)/lenny-main.tar.gz"
  mkdir -p "$(dirname "$tmp_tar")"
  curl -L https://github.com/ArchiveLabs/lenny/archive/refs/heads/main.tar.gz -o "$tmp_tar"
  tar -xzf "$tmp_tar" --strip-components=1 -C "$PROJECT_DIR"
  rm -f "$tmp_tar"
  echo "[✓] Lenny source downloaded."
fi

# Ensure ownership again (in case tar created files as root)
sudo chown -R "$USER_NAME":"$USER_NAME" "$PROJECT_DIR"

# -------------------------
# 7) Create safe .env and reader.env if they don't exist
#      Use conservative defaults. Ensure files are user-owned.
# -------------------------
cd "$PROJECT_DIR"

create_env_if_missing() {
  file="$1"
  shift
  if [ ! -f "$file" ]; then
    echo "[+] Creating $file with safe defaults..."
    cat > "$file" <<EOF
# Auto-generated .env - update as needed
LENNY_HOST=localhost
LENNY_PORT=8080
LENNY_WORKERS=1
LENNY_LOG_LEVEL=debug
OTP_SERVER=https://openlibrary.org

# DB (inside docker the host should be the compose service name)
DB_USER=librarian
DB_HOST=lenny_db
DB_PORT=5432
DB_PASSWORD=change_me_change_me
DB_NAME=lenny
DB_TYPE=postgres

# S3 defaults (MinIO service name in compose is lenny_s3)
S3_ACCESS_KEY=minio
S3_SECRET_KEY=minio123
S3_ENDPOINT=http://lenny_s3:9000
S3_PROVIDER=minio
S3_SECURE=false
EOF
    chmod 600 "$file"
    chown "$USER_NAME":"$USER_NAME" "$file"
  else
    echo "[+] $file already exists - leaving intact."
  fi
}

create_env_if_missing .env
create_env_if_missing reader.env

# -------------------------
# 8) Inform user to re-login if they were added to docker group
# -------------------------
# Check if current user is in docker group
if id -nG "$USER_NAME" | grep -qw docker; then
  echo "[✓] $USER_NAME is already in docker group."
else
  echo ""
  echo "[!] $USER_NAME is not yet in the docker group."
  echo "    You probably were just added; you MUST log out and log back in"
  echo "    (or run: newgrp docker) before running 'make start' without sudo."
  echo ""
fi

# -------------------------
# 9) Final instructions
# -------------------------
echo ""
echo "======================================================"
echo " Lenny is installed in: $PROJECT_DIR"
echo ""
echo " NEXT STEPS:"
echo "   1) If you were added to the docker group, log out and log back in now."
echo "      (or run: newgrp docker)"
echo "   2) Start Lenny:"
echo "         cd $PROJECT_DIR"
echo "         make start preload"
echo ""
echo " NOTES:"
echo " - Do NOT run 'make' or 'docker' with sudo inside the project directory."
echo " - If you get 'permission denied to /var/run/docker.sock', it means your session lacks docker group membership."
echo "======================================================"
echo ""

exit 0
