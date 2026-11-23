# hoverfly-website

WordPress site for hoverflylagoons.co.uk on an Azure VM (`Standard_B2pts_v2`, Arm, 1 GB RAM + 2 GB swap):
Ubuntu 26.04, nginx, PHP-FPM, MySQL, Let's Encrypt (certbot DNS-01 via DNSimple), fail2ban. Scripts are in `infra/`.

- Web root: `/var/www/html`
- Database: `wordpress` (user `wp_user`, localhost)
- WP-CLI: `sudo -u www-data wp ...` from `/var/www/html`
- SSH: `cd infra && ./sshCurrentVM.sh`

## Redeploy

Builds a new VM from a copy of the live site, then moves DNS to it and deletes the old one.

Needs `az login`, `secrets/dnsimpletoken.txt` and `~/.ssh/id_rsa_azure`.

1. Commit and push. The VM clones `main` from GitHub, so `infra.azcli` refuses to run otherwise.
2. Build. This copies the live database, files and certificate, then creates resource group `HoverflyLagoons<n>`:
   ```bash
   cd infra && ./infra.azcli
   ```
   It prints `<n>` at the end. Check the output contains `Congratulations, all simulated renewals succeeded`.
3. Compare every page on the live site with the new VM. Look for `DIFF` and big size changes:
   ```bash
   ./compare-pages.sh <n>
   ```
4. Switch DNS to the new VM. This also deletes the old `HoverflyLagoons*` resource groups:
   ```bash
   ./switch-dns.sh <n>
   ```
5. Check on the new VM (`./sshCurrentVM.sh`):
   ```bash
   sudo certbot certificates          # same expiry as before - not a new cert
   sudo fail2ban-client status        # sshd and wordpress jails
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://hoverflylagoons.co.uk/xmlrpc.php   # 000 = blocked
   ```

Anything changed on the live site (posts, comments) after step 2 is lost, so don't edit the site during a redeploy.

The certificate is copied from the live VM rather than requested again, which avoids Let's Encrypt's limit of
5 certificates per 7 days for the same names. The local copy holds the private key and DNSimple token, so
`infra.azcli` deletes it once uploaded. A real new certificate is only issued at renewal, about 30 days before expiry.
To see recent issuances (count only `hoverflylagoons.co.uk,www.hoverflylagoons.co.uk`):

```bash
curl -s 'https://api.certspotter.com/v1/issuances?domain=hoverflylagoons.co.uk&include_subdomains=true&expand=dns_names&expand=issuer' \
  | jq -r '.[] | [.not_before, .issuer.friendly_name, (.dns_names|join(","))] | @tsv'
```

## Health check

`sar` records memory, swap, load and pressure every minute and keeps 28 days. From WSL in `infra/`:

```bash
host=$(grep -o 'dave@[^ ]*' sshCurrentVM.sh)
ssh -o StrictHostKeyChecking=no $host '
uptime; sudo journalctl --list-boots --no-pager | tail -3
free -m; swapon --show; df -h /
echo "== OOM kills"; sudo journalctl -k --since "-1 day" --no-pager | grep -iE "oom|killed process"
echo "== swapping (pages/s) today"; sar -W | tail -3
echo "== memory pressure today (%smem, %fmem)"; sar -q MEM | tail -4
echo "== worst minute for memory pressure"; sar -q MEM | grep -v -e Average -e "^$" | sort -k5 -gr | head -2
echo "== php-fpm at max_children"; sudo grep -c "max_children" /var/log/php8.5-fpm.log
echo "== nginx 5xx today"; sudo awk "\$9 ~ /^5/" /var/log/nginx/access.log | wc -l
echo "== fail2ban (currently / total banned)"; for j in sshd wordpress; do sudo fail2ban-client status $j | grep -i banned; done
echo "== biggest processes"; ps -eo rss,comm --sort=-rss | head -6'
```

For a previous day add `-f /var/log/sysstat/saDD` to `sar` (`DD` = day of month).

| Check | Normal | Act if |
|---|---|---|
| Memory pressure `%smem` | 0-1% (a brief spike at ~01:00 from apt is fine) | regularly over 5% |
| `free -m` available | 300-450 MB | regularly under 100 MB |
| Swap used | under ~350 MB | steadily over 500 MB |
| Swapping pswpin/pswpout | near 0 | regularly over 10/s |
| OOM kills | none | any |
| Reboots | yours, or 04:00 UTC after an update | any other time |
| php-fpm `max_children` | 0 | rising each day |
| nginx 5xx | a few (scanners) | many |
| Disk `/` | ~20% | over 80% |
| fail2ban | both jails listed | a jail missing |

Swap in use with ~0% pressure is just idle pages and is fine. If memory is the problem, change `--size` in
`infra/infra.azcli` to `Standard_B2pls_v2` (4 GB) and redeploy.

## Back up and restore

Before a WordPress update, on the VM:

```bash
ts=$(date +%Y%m%d-%H%M)
sudo mysqldump --single-transaction wordpress > ~/wp-db-$ts.sql
sudo tar czf ~/wp-files-$ts.tgz -C /var/www html
```

Copy off the VM from WSL: `scp '<vm_host>:~/wp-*' <local_backup_dir>/` (`<vm_host>` is in `infra/sshCurrentVM.sh`).

Restore, on the VM:

```bash
sudo mysql wordpress < ~/wp-db-<timestamp>.sql
sudo rm -rf /var/www/html && sudo tar xzf ~/wp-files-<timestamp>.tgz -C /var/www
```

For a major version jump, update WordPress core first and check the site, then the plugins and theme.
