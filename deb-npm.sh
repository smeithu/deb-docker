#!/bin/bash
# Nginx Proxy Manager (SMETITHu Incus/Ubuntu LXD NPM) telepítő szkript
# A community-scripts/ProxmoxVE szkript NPM fork SMEITHu telepítési részét automatizálja.
# Környezet: Debian/Ubuntu alapú LXC/VM.

# --- Változók beállítása (Saját igény szerint módosítható) ---
NPM_DIR="/opt/nginx-proxy-manager"
NPM_ADMIN_PORT="81"
DB_USER="npm"
# Véletlen jelszó generálása, csupán a démonstrációhoz. Termelésben fontolja meg vault használatát.
DB_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"
MYSQL_ROOT_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"

echo "--- Nginx Proxy Manager telepítés elindítása ---"
echo "Konfigurációs könyvtár: $NPM_DIR"
echo "Adminisztrációs port: $NPM_ADMIN_PORT"
echo "DB Felhasználó: $DB_USER | Jelszó: (Generálva)"

# 1. Rendszerfrissítés és függőségek telepítése
echo -e "\n[1/5] Rendszerfrissítés, curl és Docker telepítése..."
apt update -y
apt upgrade -y
apt install -y curl

# Docker telepítése hivatalos módon (legfrissebb verzió biztosítása)
if ! command -v docker &> /dev/null; then
    echo "Docker telepítése a hivatalos szkripttel..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    # Tisztítás
    rm get-docker.sh
else
    echo "A Docker már telepítve van, kihagyva a telepítést."
fi

# A Docker szolgáltatás elindítása és engedélyezése
systemctl enable docker
systemctl start docker

# 2. Docker Compose telepítése
echo -e "\n[2/5] Docker Compose Plugin telepítése..."
# A legtöbb modern rendszer a 'docker compose' parancsot használja a beépített pluginon keresztül
if ! docker compose version &> /dev/null; then
    apt install -y docker-compose-plugin
fi

# 3. Adatkönyvtár létrehozása és navigálás
echo -e "\n[3/5] Adatkönyvtár létrehozása ($NPM_DIR)..."
mkdir -p $NPM_DIR
cd $NPM_DIR

# 4. Docker Compose fájl létrehozása
echo -e "\n[4/5] docker-compose.yml fájl generálása..."
cat << EOF > docker-compose.yml
version: '3.8'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    container_name: 'nginx-proxy-manager'
    restart: unless-stopped  # Fontos: a rendszer újraindításakor is elindul
    ports:
      # Portok a fordított proxyhoz (HTTP, HTTPS) és az Admin felülethez
      - '80:80'
      - '443:443'
      - '${NPM_ADMIN_PORT}:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    depends_on:
      - db
    environment:
      # Adatbázis konfiguráció
      DB_MYSQL_HOST: "db"
      DB_MYSQL_USER: "${DB_USER}"
      DB_MYSQL_PASSWORD: "${DB_PASS}"
      DB_MYSQL_NAME: "npm"
    networks:
      - npm-network

  db:
    image: 'mariadb:latest'
    container_name: 'npm-mariadb'
    restart: unless-stopped
    environment:
      # Adatbázis root és felhasználói jelszavak
      MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASS}"
      MYSQL_DATABASE: "npm"
      MYSQL_USER: "${DB_USER}"
      MYSQL_PASSWORD: "${DB_PASS}"
    volumes:
      - ./mysql:/var/lib/mysql
    networks:
      - npm-network

networks:
  npm-network:
    driver: bridge
EOF

# 5. A szolgáltatás elindítása
echo -e "\n[5/5] Nginx Proxy Manager indítása (Docker Compose up -d)..."

# Docker Compose parancs kiválasztása (régi vs új forma)
if docker compose version &> /dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi

# Vár néhány másodpercet, hogy a szolgáltatás elinduljon
echo "Várakozás a szolgáltatások indítására..."
sleep 15

# Ellenőrzés, hogy fut-e a konténer
if docker ps | grep -q "nginx-proxy-manager"; then
    echo -e "\n--- TELEPÍTÉS SIKERESEN BEFEJEZŐDÖTT ---"
    echo "Az Nginx Proxy Manager most fut, mint Docker konténer."
    echo ""
    echo "🔥 ELÉRÉS:"
    echo "   A konténer IP-címét használva: http://[LXC_IP]:${NPM_ADMIN_PORT}"
    echo ""
    echo "🔑 ALAPÉRTELMEZETT BELÉPÉSI ADATOK (azonnal változtassa meg!):"
    echo "   Email:    admin@example.com"
    echo "   Jelszó:   changeme"
    echo ""
    echo "📝 FONTOS INFORMÁCIÓK:"
    echo "   - A DB jelszavak biztonságosan tárolva vannak a docker-compose.yml fájlban"
    echo "   - Adatok a következő könyvtárakban találhatók: $NPM_DIR/"
    echo "   - A szolgáltatás automatikusan újraindul a rendszer indulásakor"
    echo ""
    echo "A konténerek állapota:"
    docker ps --filter "name=nginx-proxy-manager\|npm-mariadb"
else
    echo -e "\n⚠️ FIGYELMEZTETÉS: A telepítés befejeződött, de a konténer nem fut."
    echo "Ellenőrizze a naplókat: docker logs nginx-proxy-manager"
    exit 1
fi
