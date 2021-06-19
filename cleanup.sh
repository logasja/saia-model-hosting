#!/bin/bash

if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    echo "Not running as root"
    exit
fi

echo "### Cleaning up environment"
docker-compose down
docker volume prune -f
rm -rf data/
rm docker-compose.yaml