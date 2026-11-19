#!/bin/bash

# Fetches every URL in the live site's sitemap from the live server and from the new VM
# (before DNS is switched) and shows status code and size side by side.
# usage: ./compare-pages.sh 123   (the number infra.azcli printed)
# Sizes will differ slightly (nonces, PHP version) - look for DIFF and big size changes

if [ -z "$1" ]; then
  echo "usage: ./compare-pages.sh <number>"
  exit 1
fi

site=https://hoverflylagoons.co.uk
ip=$(az network public-ip show -g HoverflyLagoons$1 -n publicIP$1 --query ipAddress -o tsv)
echo "new VM is $ip"

urls="$site/"
for sitemap in $(curl -s $site/wp-sitemap.xml | grep -o '<loc>[^<]*' | sed 's/<loc>//'); do
  urls="$urls $(curl -s $sitemap | grep -o '<loc>[^<]*' | sed 's/<loc>//')"
done

printf "%-6s %-9s %-6s %-9s %s\n" live bytes new bytes url
for url in $urls; do
  live=$(curl -s -o /dev/null -w "%{http_code} %{size_download}" $url)
  new=$(curl -s -o /dev/null -w "%{http_code} %{size_download}" --resolve hoverflylagoons.co.uk:443:$ip $url)
  flag=""
  if [ "${live%% *}" != "${new%% *}" ]; then flag="DIFF"; fi
  printf "%-6s %-9s %-6s %-9s %s %s\n" $live $new $url $flag
done
