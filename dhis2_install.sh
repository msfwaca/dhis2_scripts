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

# Install and configure Tomcat 9
log "Installing and configuring Tomcat 9..."
sudo apt-get install -y tomcat9-user
sudo tomcat9-instance-create /home/dhis/tomcat-dhis
sudo chown -R dhis:dhis /home/dhis/tomcat-dhis/

# Set environment variables in setenv.sh
log "Setting environment variables in Tomcat's setenv.sh..."
sudo bash -c 'cat > /home/dhis/tomcat-dhis/bin/setenv.sh <<EOF
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export DHIS2_HOME=/home/dhis/config
EOF'

# Make sure setenv.sh is executable
sudo chmod +x /home/dhis/tomcat-dhis/bin/setenv.sh

# Deploy DHIS2
log "Deploying DHIS2..."
sudo mv dhis.war /home/dhis/tomcat-dhis/webapps/dhis.war

# Ensure Tomcat user has the correct permissions
log "Setting permissions for Tomcat directories..."
sudo chown -R dhis:dhis /home/dhis/config
sudo chown dhis:dhis /home/dhis/tomcat-dhis/webapps/dhis.war

# Start the Tomcat instance
log "Starting the Tomcat instance..."
sudo -u dhis /home/dhis/tomcat-dhis/bin/startup.sh

log "DHIS2 installation complete. Access it at http://your_server_ip:8080/dhis"
