#!/usr/bin/env bash
# ------------------------------------------------------------------
# deploy.sh - Automated Deployment Script for Dockerized Application
# Author: Oyemike Chukuneku
# Version: 1.0
# Description:
#   Automates cloning a git repo, connecting to a remote Linux server,
#   installing Docker + Nginx, deploying a containerized app, and
#   configuring Nginx as a reverse proxy.
# ------------------------------------------------------------------

set -euo pipefail
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# ---------- Logging ----------
log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
  echo -e "\n❌ ERROR: $*" | tee -a "$LOG_FILE"
  exit 1
}

trap 'error_exit "Script interrupted unexpectedly."' INT TERM

# ---------- Collect Parameters ----------
log "Collecting user input..."

read -rp "Enter Git Repository URL: " GIT_URL
[[ -z "$GIT_URL" ]] && error_exit "Repository URL cannot be empty."

read -rp "Enter Personal Access Token (PAT): " PAT
[[ -z "$PAT" ]] && error_exit "PAT cannot be empty."

read -rp "Enter Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -rp "Enter Remote Server Username: " SSH_USER
[[ -z "$SSH_USER" ]] && error_exit "SSH username required."

read -rp "Enter Remote Server IP Address: " SERVER_IP
[[ -z "$SERVER_IP" ]] && error_exit "Server IP required."

read -rp "Enter SSH Private Key Path: " SSH_KEY
[[ ! -f "$SSH_KEY" ]] && error_exit "Invalid SSH key path."

read -rp "Enter Application internal container port: " APP_PORT
[[ -z "$APP_PORT" ]] && error_exit "App port required."

# ---------- Clone or Update Repository ----------
REPO_NAME=$(basename "$GIT_URL" .git)

if [[ -d "$REPO_NAME" ]]; then
  log "Repository already exists. Pulling latest changes..."
  cd "$REPO_NAME" && git pull || error_exit "Failed to pull latest changes."
else
  log "Cloning repository..."
  git clone "https://${PAT}@${GIT_URL#https://}" || error_exit "Failed to clone repository."
  cd "$REPO_NAME"
fi

git checkout "$BRANCH" || error_exit "Failed to switch to branch: $BRANCH"
log "Repository cloned and branch checked out."

# ---------- Validate Docker File ----------
if [[ -f "docker-compose.yml" ]]; then
  DEPLOY_MODE="compose"
elif [[ -f "Dockerfile" ]]; then
  DEPLOY_MODE="dockerfile"
else
  error_exit "No Dockerfile or docker-compose.yml found in repository."
fi
log "Deployment mode: $DEPLOY_MODE"

# ---------- SSH Connectivity Check ----------
log "Testing SSH connectivity to ${SERVER_IP}..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${SERVER_IP}" "echo Connected"; then
  error_exit "Unable to connect to remote server."
fi

# ---------- Prepare Remote Environment ----------
log "Setting up remote environment..."

ssh -i "$SSH_KEY" "${SSH_USER}@${SERVER_IP}" bash -s <<'EOF'
set -e

echo "Updating system packages..."
sudo apt-get update -y

echo "Installing Docker, Docker Compose, and Nginx..."
sudo apt-get install -y docker.io docker-compose nginx

sudo systemctl enable docker --now
sudo usermod -aG docker "$USER" || true
sudo systemctl enable nginx --now

docker --version
docker-compose --version
nginx -v
EOF

log "Remote environment prepared."

# ---------- Transfer Files ----------
log "Transferring project files to remote server..."
rsync -avz -e "ssh -i $SSH_KEY" --exclude '.git' "./" "${SSH_USER}@${SERVER_IP}:/home/${SSH_USER}/${REPO_NAME}"

# ---------- Deploy Dockerized Application ----------
log "Deploying application remotely..."

ssh -i "$SSH_KEY" "${SSH_USER}@${SERVER_IP}" bash -s <<EOF
set -e
cd ~/${REPO_NAME}

echo "Stopping old containers..."
sudo docker-compose down || true
sudo docker ps -q --filter "ancestor=${REPO_NAME}" | xargs -r sudo docker stop

if [[ -f docker-compose.yml ]]; then
  echo "Starting containers using Docker Compose..."
  sudo docker-compose up -d --build
else
  echo "Building and running Docker image manually..."
  sudo docker build -t ${REPO_NAME}_app .
  sudo docker run -d -p ${APP_PORT}:${APP_PORT} --name ${REPO_NAME}_container ${REPO_NAME}_app
fi

sleep 5
sudo docker ps
EOF

# ---------- Configure Nginx ----------
log "Configuring Nginx as reverse proxy..."

NGINX_CONF="/etc/nginx/sites-available/${REPO_NAME}.conf"

ssh -i "$SSH_KEY" "${SSH_USER}@${SERVER_IP}" "bash -s" <<EOF
set -e
cat <<NGINXCONF | sudo tee $NGINX_CONF > /dev/null
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINXCONF

sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
EOF

log "Nginx reverse proxy configured successfully."

# ---------- Validate Deployment ----------
log "Validating deployment..."

ssh -i "$SSH_KEY" "${SSH_USER}@${SERVER_IP}" bash -s <<EOF
sudo systemctl status docker | grep active
sudo docker ps
curl -I http://localhost || true
EOF

log "✅ Deployment completed successfully! Access the app at: http://${SERVER_IP}"

exit 0
