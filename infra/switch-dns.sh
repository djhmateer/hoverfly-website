#!/bin/bash

# Points hoverflylagoons.co.uk and www at the new VM, then deletes the other HoverflyLagoons resource groups
# Run only after ./compare-pages.sh looks good
# usage: ./switch-dns.sh 123   (the number infra.azcli printed)

if [ -z "$1" ]; then
  echo "usage: ./switch-dns.sh <number>"
  exit 1
fi

rg=HoverflyLagoons$1
ip=$(az network public-ip show -g $rg -n publicIP$1 --query ipAddress -o tsv)
if [ -z "$ip" ]; then
  echo "no public IP found for $rg"
  exit 1
fi

# don't echo commands so the token isn't printed
token=$(head -n 1 ../secrets/dnsimpletoken.txt)

# 90242861 = hoverflylagoons.co.uk, 90242877 = www
for record in 90242861 90242877; do
  url=https://api.dnsimple.com/v2/63829/zones/hoverflylagoons.co.uk/records/$record

  # A records take an IP, ALIAS/CNAME take a hostname
  type=$(curl -s $url -H "Authorization: Bearer ${token}" -H "Accept: application/json" | grep -o '"type":"[A-Z]*"' | cut -d'"' -f4)
  if [ "$type" = "A" ]; then
    content=$ip
  else
    content=hoverflylagoons$1.westeurope.cloudapp.azure.com
  fi

  echo "record $record ($type) -> $content"
  curl -s $url -H "Authorization: Bearer ${token}" -H "Accept: application/json" -H "Content-Type: application/json" \
    -X PATCH -d "{\"content\": \"$content\", \"ttl\": 60}"
  echo ""
done

# delete old resource groups
for rgtodel in $(az group list --query "[?starts_with(name, 'HoverflyLagoons')].name" --output tsv); do
  if [ "$rgtodel" != "$rg" ]; then
    echo "deleting $rgtodel"
    az group delete --name $rgtodel --no-wait --yes
  fi
done
