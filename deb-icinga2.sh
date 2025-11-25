#!/bin/bash
# Icinga2 Monitoring Suite (Docker) telepítő szkript SMEITHu
# Környezet: Debian 13 LXC/VM.

# --- Változók beállítása ---
ICINGA_DIR="/opt/icinga2"
ICINGA_WEB_PORT="8080"

# Jelszó generálás - EGYSZERŰBB karakterkészlet
DB_USER="icinga"
DB_PASS="icinga_pass_$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)"
MYSQL_ROOT_PASS="root_pass_$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)"
ICINGA_DB="icinga2idom"

echo "--- Icinga2 Monitoring Suite telepítés elindítása (Docker) ---"

# 1. Rendszerfrissítés és Docker telepítése
echo -e "\n[1/5] Rendszerfrissítés és Docker telepítése..."
apt update -y
apt upgrade -y
apt install -y curl gnupg

# Docker telepítése
if ! command -v docker &> /dev/null; then
    echo "Docker telepítése..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
fi

systemctl enable docker
systemctl start docker

# 2. Docker Compose telepítése
echo -e "\n[2/5] Docker Compose telepítése..."
if ! docker compose version &> /dev/null; then
    apt install -y docker-compose-plugin
fi

# 3. Adatkönyvtár létrehozása
echo -e "\n[3/5] Adatkönyvtár és struktúra létrehozása ($ICINGA_DIR)..."
mkdir -p $ICINGA_DIR
cd $ICINGA_DIR
mkdir -p mariadb icinga2-config icinga2-logs

# Jogosultságok beállítása
chmod 755 mariadb icinga2-config icinga2-logs

# 4. Docker Compose fájl létrehozása (JAVÍTOTT - egyszerűbb jelszavakkal)
echo -e "\n[4/5] **docker-compose.yml** fájl generálása..."
cat << EOF > docker-compose.yml
services:
  # Icinga 2 Core + Icinga Web 2
  icinga2:
    image: 'jordan/icinga2:latest'
    container_name: 'icinga2-full'
    restart: unless-stopped
    ports:
      - '${ICINGA_WEB_PORT}:80'
      - '5665:5665'
    volumes:
      - ./icinga2-config:/etc/icinga2
      - ./icinga2-logs:/var/log/icinga2
    depends_on:
      mariadb:
        condition: service_healthy
    environment:
      ICINGA_MASTER: "1"
      ICINGA_API_USERS: "root:icinga"
      ICINGA_FEATURE_IDO: "1"
      ICINGA_FEATURE_IDO_HOST: "mariadb"
      ICINGA_FEATURE_IDO_USER: "${DB_USER}"
      ICINGA_FEATURE_IDO_PASSWORD: "${DB_PASS}"
      ICINGA_FEATURE_IDO_DATABASE: "${ICINGA_DB}"
      ICINGA_FEATURE_ICINGAWEB: "1"
      ICINGA_FEATURE_ICINGAWEB_ADMIN_PASS: "admin123"
    networks:
      - icinga-net

  mariadb:
    image: 'mariadb:latest'
    container_name: 'icinga-mariadb'
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASS}"
      MYSQL_DATABASE: "${ICINGA_DB}"
      MYSQL_USER: "${DB_USER}"
      MYSQL_PASSWORD: "${DB_PASS}"
      MYSQL_CHARSET: "utf8"
      MYSQL_COLLATION: "utf8_general_ci"
    volumes:
      - ./mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      start_interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - icinga-net

networks:
  icinga-net:
    driver: bridge
EOF

# 5. A szolgáltatás elindítása (JAVÍTOTT - healthcheck használata)
echo -e "\n[5/5] **Icinga2** indítása..."

echo "1. lépés: MariaDB indítása healthcheck-kel..."
docker compose up -d mariadb

echo "2. lépés: Adatbázis inicializálásának várakozása (maximum 2 perc)..."

# Healthcheck alapú várakozás
for i in {1..12}; do
    CONTAINER_STATUS=$(docker inspect --format='{{.State.Health.Status}}' icinga-mariadb 2>/dev/null)
    
    if [ "$CONTAINER_STATUS" = "healthy" ]; then
        echo "✅ Adatbázis HEALTHY állapotban."
        break
    elif [ "$CONTAINER_STATUS" = "starting" ]; then
        echo "⏳ ($i/12) Adatbázis inicializálása folyamatban... ($CONTAINER_STATUS)"
    else
        echo "⏳ ($i/12) Adatbázis állapota: $CONTAINER_STATUS"
    fi
    
    sleep 10
done

# Végső ellenőrzés
if docker exec icinga-mariadb mysql -u root -p"${MYSQL_ROOT_PASS}" -e "SHOW DATABASES;" 2>/dev/null; then
    echo "✅ Adatbázis teljesen kész és elérhető."
else
    echo "⚠️ Adatbázis nem válaszol, de folytatjuk a telepítést..."
    # Naplók megjelenítése diagnosztikához
    echo "MariaDB naplók:"
    docker logs icinga-mariadb --tail 20
fi

echo "3. lépés: Icinga2 teljes stack indítása..."
docker compose up -d

echo "Várakozás a szolgáltatások indítására..."
sleep 30

# 6. Végső ellenőrzés
echo -e "\n[6/6] Végső ellenőrzés..."
if docker ps --filter "name=icinga2-full" --filter "status=running" | grep -q "icinga2-full" && \
   docker ps --filter "name=icinga-mariadb" --filter "status=running" | grep -q "icinga-mariadb"; then
    echo -e "\n--- 🚀 TELEPÍTÉS SIKERESEN BEFEJEZŐDÖTT ---"
    echo "Az **Icinga 2 Core + Icinga Web 2** és **MariaDB** fut."
    echo ""
    echo "🔥 **ELÉRÉS**: http://[LXC_IP]:${ICINGA_WEB_PORT}"
    echo "   Felhasználó: icingaadmin"
    echo "   Jelszó: icinga"
    echo ""
    echo "📝 **ADATBÁZIS ADATOK**:"
    echo "   Host: mariadb | Felhasználó: ${DB_USER} | Jelszó: ${DB_PASS} | Adatbázis: ${ICINGA_DB}"
    echo ""
    echo "📋 **KONTÉNER ÁLLAPOT**:"
    docker ps --filter "name=icinga2-full\|icinga-mariadb" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    # További diagnosztika
    echo ""
    echo "🔍 **DIAGNOSZTIKA**:"
    echo "MariaDB napló: docker logs icinga-mariadb"
    echo "Icinga2 napló: docker logs icinga2-full"
    echo "Állj meg: cd $ICINGA_DIR && docker compose down"
    
else
    echo -e "\n⚠️ Telepítés részben sikertelen. Naplók ellenőrzése:"
    echo "docker logs icinga-mariadb"
    echo "docker logs icinga2-full"
    echo ""
    echo "Próbáld meg manuálisan indítani:"
    echo "cd $ICINGA_DIR && docker compose up -d"
    exit 1
fi
