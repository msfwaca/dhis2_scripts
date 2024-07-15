#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to log and echo messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $@"
}

# Update and upgrade the system
log "Updating and upgrading the system..."
sudo apt-get update && sudo apt-get upgrade -y

# Install Java (OpenJDK 11)
log "Installing Java (OpenJDK 11)..."
sudo apt-get install openjdk-11-jdk -y

# Install PostgreSQL 16 and PostGIS
log "Installing PostgreSQL 16 and PostGIS..."
sudo apt-get install wget ca-certificates -y
echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo apt-get update
sudo apt-get install postgresql-16 postgresql-client-16 postgis -y

# Configure PostgreSQL
log "Configuring PostgreSQL..."
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Check if the database already exists
log "Checking if the DHIS2 database already exists..."
DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='dhis2'")

if [ "$DB_EXISTS" = "1" ]; then
    log "Database dhis2 already exists. Skipping database creation."
else
    log "Creating DHIS2 database and user..."
    sudo -u postgres psql -c "CREATE DATABASE dhis2;"
    sudo -u postgres psql -c "CREATE USER dhis WITH PASSWORD 'dhis';"
    sudo -u postgres psql -c "ALTER DATABASE dhis2 OWNER TO dhis;"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE dhis2 TO dhis;"
    log "Enabling PostGIS extension on dhis2 database..."
    sudo -u postgres psql -d dhis2 -c "CREATE EXTENSION postgis;"
fi

# Install required libraries
log "Installing required libraries..."
sudo apt-get install apt-transport-https ca-certificates curl software-properties-common -y

# Install DHIS2
DHIS2_VERSION="40.4.0"
log "Downloading DHIS2 version $DHIS2_VERSION..."
wget https://releases.dhis2.org/40/dhis2-stable-$DHIS2_VERSION.war

# Verify the download
if [ ! -f "dhis2-stable-$DHIS2_VERSION.war" ]; then
    log "Failed to download dhis2-stable-$DHIS2_VERSION.war"
    exit 1
fi

# Rename the WAR file
log "Renaming the WAR file..."
mv dhis2-stable-$DHIS2_VERSION.war dhis.war

# Check if DHIS2 user exists, create if it does not
if id "dhis" &>/dev/null; then
    log "User dhis already exists. Skipping user creation."
else
    log "Creating DHIS2 user..."
    sudo useradd -m -d /home/dhis -s /bin/bash dhis
fi

# Create DHIS2 home directory if it doesn't exist
if [ ! -d /home/dhis/config ]; then
    log "Creating DHIS2 home directory..."
    sudo mkdir -p /home/dhis/config
fi

# Create DHIS2 configuration file
log "Creating DHIS2 configuration file..."
sudo bash -c 'cat > /home/dhis/config/dhis.conf <<EOF
connection.dialect = org.hibernate.dialect.PostgreSQLDialect
connection.driver_class = org.postgresql.Driver
connection.url = jdbc:postgresql://localhost:5432/dhis2
connection.username = dhis
connection.password = dhis
connection.schema = update
EOF'

# Ensure the DHIS2 configuration file is readable
log "Setting permissions for DHIS2 configuration file..."
sudo chown dhis:dhis /home/dhis/config/dhis.conf
sudo chmod 600 /home/dhis/config/dhis.conf

# Download and install Tomcat 9 manually
log "Downloading and installing Tomcat 9..."
cd /tmp
wget https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.64/bin/apache-tomcat-9.0.64.tar.gz
sudo tar -xzf apache-tomcat-9.0.64.tar.gz -C /opt/
sudo mv /opt/apache-tomcat-9.0.64 /opt/tomcat9
sudo chown -R dhis:dhis /opt/tomcat9

# Set environment variables in setenv.sh
log "Setting environment variables in Tomcat's setenv.sh..."
sudo bash -c 'cat > /opt/tomcat9/bin/setenv.sh <<EOF
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export DHIS2_HOME=/home/dhis/config
EOF'

# Make sure setenv.sh is executable
sudo chmod +x /opt/tomcat9/bin/setenv.sh

# Deploy DHIS2
log "Deploying DHIS2..."
sudo mv dhis.war /opt/tomcat9/webapps/

# Ensure Tomcat user has the correct permissions
log "Setting permissions for Tomcat directories..."
sudo chown -R dhis:dhis /opt/tomcat9/webapps
sudo chown dhis:dhis /opt/tomcat9/webapps/dhis.war

# Create a systemd service file for Tomcat 9
log "Creating systemd service file for Tomcat 9..."
sudo bash -c 'cat > /etc/systemd/system/tomcat9.service <<EOF
[Unit]
Description=Apache Tomcat 9 Web Application Container
After=network.target

[Service]
Type=forking
User=dhis
Group=dhis
Environment="JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64"
Environment="DHIS2_HOME=/home/dhis/config"
Environment="CATALINA_PID=/opt/tomcat9/temp/tomcat.pid"
Environment="CATALINA_HOME=/opt/tomcat9"
Environment="CATALINA_BASE=/opt/tomcat9"
ExecStart=/opt/tomcat9/bin/startup.sh
ExecStop=/opt/tomcat9/bin/shutdown.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF'

# Reload systemd and restart Tomcat
log "Reloading systemd and restarting Tomcat..."
sudo systemctl daemon-reload
sudo systemctl start tomcat9
sudo systemctl enable tomcat9

# Install Nginx
log "Installing Nginx..."
sudo apt-get install nginx -y

# Configure Nginx as a reverse proxy
DOMAIN_NAME="his-dev.msf-waca.org" #  domain name
log "Configuring Nginx as a reverse proxy..."
sudo bash -c 'cat > /etc/nginx/sites-available/dhis2 <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 100M;
    }
}
EOF'

# Enable the Nginx configuration
log "Enabling the Nginx configuration..."
sudo ln -s /etc/nginx/sites-available/dhis2 /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# Install Certbot and get SSL certificate
log "Installing Certbot and getting SSL certificate..."
sudo apt-get install certbot python3-certbot-nginx -y
sudo certbot --nginx -d $DOMAIN_NAME

log "DHIS2 installation complete. Access it at https://$DOMAIN_NAME"
