#!/usr/bin/env bash
set -e

echo "=============================================="
echo " Jitsi Meet + Jicofo + Whisper ASR Installer"
echo "=============================================="

echo "[1/9] System info:"
lsb_release -d 2>/dev/null || cat /etc/os-release | head -3
echo "RAM: $(free -h | awk '/Mem:/{print $2}')"
echo "Disk: $(df -h / | awk 'NR==2{print $4 " free"}')"
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo "IP: $LOCAL_IP"

echo "[2/9] Checking Docker..."
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  sudo apt-get update -y -q
  sudo apt-get install -y -q ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y -q
  sudo apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  echo "Docker installed."
else
  echo "Docker already installed: $(docker --version)"
fi

echo "[3/9] Starting Docker daemon..."
if ! docker info &>/dev/null 2>&1; then
  sudo service docker start 2>/dev/null || true
  sleep 3
  if ! docker info &>/dev/null 2>&1; then
    sudo dockerd > /tmp/dockerd.log 2>&1 &
    sleep 5
  fi
fi

echo "[4/9] Setting up docker-jitsi-meet..."
JITSI_DIR="/home/dt/docker-jitsi-meet"
if [ ! -d "$JITSI_DIR" ]; then
  git clone https://github.com/jitsi/docker-jitsi-meet.git "$JITSI_DIR"
else
  git -C "$JITSI_DIR" pull --ff-only || true
fi
cd "$JITSI_DIR"
[ ! -f ".env" ] && cp env.example .env

echo "[5/9] Configuring .env..."
for p in JICOFO_AUTH_PASSWORD JVB_AUTH_PASSWORD JIGASI_XMPP_PASSWORD JIBRI_RECORDER_PASSWORD JIBRI_XMPP_PASSWORD; do
  sed -i "s/^$p=.*/$p=$(openssl rand -hex 16)/" .env
done

if grep -q "^#PUBLIC_URL=" .env || grep -q "^PUBLIC_URL=" .env; then
  sed -i "s|^#*PUBLIC_URL=.*|PUBLIC_URL=http://$LOCAL_IP:8080|" .env
else
  echo "PUBLIC_URL=http://$LOCAL_IP:8080" >> .env
fi

if grep -q "^#*DOCKER_HOST_ADDRESS=" .env; then
  sed -i "s|^#*DOCKER_HOST_ADDRESS=.*|DOCKER_HOST_ADDRESS=$LOCAL_IP|" .env
else
  echo "DOCKER_HOST_ADDRESS=$LOCAL_IP" >> .env
fi

grep -q "^ENABLE_TRANSCRIPTIONS" .env || echo "ENABLE_TRANSCRIPTIONS=1" >> .env
grep -q "^JIGASI_TRANSCRIBER_RECORD_AUDIO" .env || echo "JIGASI_TRANSCRIBER_RECORD_AUDIO=true" >> .env
grep -q "^JIGASI_TRANSCRIBER_SEND_TXT" .env || echo "JIGASI_TRANSCRIBER_SEND_TXT=true" >> .env

echo "[6/9] Creating config directories..."
CONFIG_DIR="/home/dt/.jitsi-meet-cfg"
mkdir -p "$CONFIG_DIR"/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}
grep -q "^CONFIG=" .env || echo "CONFIG=$CONFIG_DIR" >> .env

echo "[7/9] Creating transcriber.yml..."
cat > "$JITSI_DIR/transcriber.yml" << EOFYML
version: '3.8'
services:
  jigasi:
    image: jitsi/jigasi:latest
    restart: unless-stopped
    volumes:
      - \${CONFIG:-~/.jitsi-meet-cfg}/jigasi:/config:Z
      - \${CONFIG:-~/.jitsi-meet-cfg}/transcripts:/tmp/transcripts:Z
    environment:
      - XMPP_SERVER=prosody
      - XMPP_DOMAIN=\${XMPP_DOMAIN:-meet.jitsi}
      - XMPP_AUTH_DOMAIN=auth.\${XMPP_DOMAIN:-meet.jitsi}
      - XMPP_MUC_DOMAIN=muc.\${XMPP_DOMAIN:-meet.jitsi}
      - JIGASI_XMPP_USER=jigasi
      - JIGASI_XMPP_PASSWORD=\${JIGASI_XMPP_PASSWORD}
      - JIGASI_MODE=transcriber
      - ENABLE_TRANSCRIPTIONS=1
      - JIGASI_TRANSCRIBER_RECORD_AUDIO=true
      - JIGASI_TRANSCRIBER_SEND_TXT=true
      - JIGASI_TRANSCRIBER_CUSTOM_SERVICE=org.jitsi.jigasi.transcription.WhisperTranscriptionService
      - JIGASI_TRANSCRIBER_WHISPER_URL=ws://whisper:8000/asr/transcribe/streaming
    networks:
      - meet.jitsi
    depends_on:
      - prosody
      - whisper

  whisper:
    image: onerahmet/openai-whisper-asr-webservice:latest
    restart: unless-stopped
    environment:
      - ASR_MODEL=base
      - ASR_ENGINE=faster_whisper
    volumes:
      - whisper_models:/root/.cache/whisper
    networks:
      - meet.jitsi

volumes:
  whisper_models:
networks:
  meet.jitsi:
    external: true
EOFYML

echo "[8/9] Pulling and launching stack..."
cd "$JITSI_DIR"
docker compose -f docker-compose.yml pull 2>&1 | tail -5
docker compose -f transcriber.yml pull 2>&1 | tail -5
docker compose -f docker-compose.yml -f transcriber.yml up -d

echo "[9/9] Checking containers..."
sleep 10
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

sudo ufw allow 80/tcp 2>/dev/null || true
sudo ufw allow 443/tcp 2>/dev/null || true
sudo ufw allow 8080/tcp 2>/dev/null || true
sudo ufw allow 10000/udp 2>/dev/null || true
sudo ufw allow 4443/tcp 2>/dev/null || true

echo "=============================================="
echo " Access Jitsi Meet: http://$LOCAL_IP:8080"
echo "=============================================="
