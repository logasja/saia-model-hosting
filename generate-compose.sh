#!/bin/bash

if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    echo "Not running as root"
    exit
fi

domains=(ipfs.example.org) # replace with your personal domains
rsa_key_size=2048         # set the key size to whatever you'd like
data_path="./data"        # define the path
email="example@email.com"  # replace with your actual address
cluster_name="clevername" # name the ipfs cluster
staging=0                 # Set to 1 if testing

# if [ -d "$data_path" ]; then
#   read -p "Existing data found for $domains. Continue and replace existing configs? (y/N) " decision
#   if [ "$decision" != "Y"] && [ "$decision" !="y" ]; then
#     exit
#   fi
# fi

mkdir -p "$data_path/webroot"

# Generating cluster secret or get it from file
if [ ! -e "./secret.txt" ]; then
  hexdump -n 32 -e '4/4 "%08X" 1 ""' /dev/random > ./cluster_secret.txt
  # od  -vN 32 -An -tx1 /dev/urandom | base64 -w 0 - |  od -t x8 -An | tr -d ' \n' > ./cluster_secret.txt
  cluster_secret=$(cat cluster_secret.txt)
  echo $cluster_secret
fi

if [ ! -e "$data_path/nginx-conf/nginx.conf" ]; then
  echo "### Generating initial nginx.conf"
  mkdir -p "$data_path/conf/nginx-conf"
  echo -n "server {
  listen 80;
  listen [::]:80;

  server_name" > "$data_path/conf/nginx-conf/nginx.conf"
  for domain in "${domains[@]}"; do
    echo -n " $domain" >> "$data_path/conf/nginx-conf/nginx.conf"
  done
  echo ";
  server_tokens off;

  location ~ /.well-known/acme-challenge/ {
    allow all;
    root /var/www/html;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}" >> "$data_path/conf/nginx-conf/nginx.conf"
  echo
fi

# Generate dhparam
if [ ! -e "$data_path/conf/dhparam/dhparam-$rsa_key_size.pem" ]; then
  echo "### Generating dhparam ..."
  mkdir -p "$data_path/conf"
  mkdir -p "$data_path/conf/dhparam"
  openssl dhparam -out "$data_path/conf/dhparam/dhparam-$rsa_key_size.pem" $rsa_key_size
  echo
fi

# Generate the docker compose file
if [ ! -e "./docker-compose.yaml" ]; then
  echo "### Generating docker-compose"
  echo -n "version: \"3.8\"
services:
  ipfs:
    container_name: ipfs
    image: ipfs/go-ipfs:latest
    restart: unless-stopped
    environment:
      - IPFS_PROFILE=server
    volumes:
      - ./data/ipfs:/data/ipfs
    # ports:
    # - \"4001:4001\" # ipfs swarm - expose if needed/wanted
    # - \"5001:5001\" # ipfs api - expose if needed/wanted
    # - \"8080:8080\" # ipfs gateway - expose if needed/wanted
      
  cluster:
    container_name: cluster
    image: ipfs/ipfs-cluster:latest
    restart: unless-stopped
    depends_on:
      - ipfs
    environment:
      CLUSTER_PEERNAME: cluster-$cluster_name
      CLUSTER_SECRET: $cluster_secret
      CLUSTER_IPFSHTTP_NODEMULTIADDRESS: /dns4/ipfs/tcp/5001
      CLUSTER_CRDT_TRUSTEDPEERS: '*' # Trust all peers in Cluster
      CLUSTER_RESTAPI_HTTPLISTENMULTIADDRESS: /ip4/0.0.0.0/tcp/9094 # Expose API
      CLUSTER_MONITORPINGINTERVAL: 2s # Speed up peer discovery
    ports:
          # Open API port (allows ipfs-cluster-ctl usage on host)
          - \"127.0.0.1:9094:9094\"
          # The cluster swarm port would need  to be exposed if this container
          # was to connect to cluster peers on other hosts.
          # But this is just a testing cluster.
          # Cluster IPFS proxy endpoint
          # - \"9096:9096\"
    volumes:
      - ./data/cluster:/data/ipfs-cluster

  nginx:
    image: nginx:mainline-alpine
    container_name: nginx
    # restart: unless-stopped
    volumes:
      - web-root:/var/www/html
      - ./data/conf/nginx-conf:/etc/nginx/conf.d
      - certbot-etc:/etc/letsencrypt
      - certbot-var:/var/lib/letsencrypt
      - dhparam:/etc/ssl/certs
    ports:
      - \"80:80\"
      - \"443:443\"
    depends_on:
      - ipfs
      - cluster
    links:
      - \"ipfs:ipfs\"
      - \"cluster:cluster\"
  certbot:
    image: certbot/certbot
    container_name: certbot
    depends_on: 
      - nginx
    volumes:
      - certbot-etc:/etc/letsencrypt
      - certbot-var:/var/lib/letsencrypt
      - web-root:/var/www/html
    command: certonly --webroot --webroot-path=/var/www/html --email $email --agree-tos --no-eff-email" > ./docker-compose.yaml
  if [ $staging -eq 1 ]; then
    echo -n " --staging" >> ./docker-compose.yaml
  fi

  echo -n " --force-renewal" >> ./docker-compose.yaml 

  for domain in "${domains[@]}"; do
    echo -n " -d $domain" >> ./docker-compose.yaml
  done

  echo "

volumes:
  certbot-etc:
  certbot-var:
  web-root:
    driver: local
    driver_opts: 
      type: none
      device: $data_path/webroot
      o: bind
  dhparam:
    driver: local
    driver_opts:
      type: none
      device: $data_path/conf/dhparam
      o: bind
    

" >> ./docker-compose.yaml
  echo
fi

echo "### Obtaining SSL Certs and Creds"
docker-compose up -d
echo

# Pause for 30 seconds to allow containers to run
sleep 30

# Check if cert container exited correctly
if [ $( docker-compose ps certbot | grep "Exit 0" | wc -l ) -eq 1 ]; then
  # Certbot exited correctly
  docker-compose exec webserver ls -la /etc/letsencrypt/live
  echo "Certbot exited correctly, make sure your domain is listed above!"
else
  # Certbot did not exit correctly
  docker-compose logs certbot
  echo "Something went wrong, check out the logs above for more info."
  exit 1
fi

# Replace command line in compose
echo "### Modifying docker compose"
sed -i "s|--staging ||g" ./docker-compose.yaml
echo

# Add ssl portion to nginx.conf
echo "### Generating secure nginx.conf"
echo -n "server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;

  server_name" >> "$data_path/conf/nginx-conf/nginx.conf"
  for domain in "${domains[@]}"; do
    echo -n " $domain" >> "$data_path/conf/nginx-conf/nginx.conf"
  done
  echo -n ";
  server_tokens off;

  ssl_certificate /etc/letsencrypt/live/$domains/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$domains/privkey.pem;
  
  ssl_buffer_size 8k;

  # curl https://ssl-config.mozilla.org/ffdhe2048.txt > /path/to/dhparam
  ssl_dhparam /etc/ssl/certs/dhparam-2048.pem;

  ssl_session_timeout 1d;
  ssl_session_cache shared:MOzSSL:10m;
  ssl_session_tickets off;

  # Intermediate config from https://ssl-config.mozilla.org/
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
  ssl_prefer_server_ciphers off;

  # HSTS (ngx_http_headers_module is required) (63072000 seconds)
  add_header Strict-Transport-Security \"max-age=63072000\" always;

  # OCSP stapling
  ssl_stapling on;
  ssl_stapling_verify on;

  location / {
    proxy_pass  http://ipfs:8080/;
    proxy_set_header    Host                \$http_host;
    proxy_set_header    X-Real-IP           \$remote_addr;
    proxy_set_header    X-Forwarded-For     \$proxy_add_x_forwarded_for;
  }
}" >> "$data_path/conf/nginx-conf/nginx.conf"

echo "### Spinning up, once done you should be able to use ipfs gateway"
docker-compose up -d --force-recreate --no-deps nginx
sleep 15
if [ $( docker-compose ps nginx | grep "Up" | wc -l ) -eq 1 ]; then
  # Certbot exited correctly
  docker-compose ps
  echo "Nginx is running, test out your ipfs gateway!"
else
  # Certbot did not exit correctly
  docker-compose logs nginx
  echo "Something went wrong, check out the logs above for more info."
  docker-compose down
  exit 1
fi
echo

# for domain in "${domains[@]}"; do
#   echo "### Removing old certificate for $domain ..."
