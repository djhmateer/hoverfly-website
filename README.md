# hoverfly-website

WordPress site on an Azure VM (Ubuntu, nginx, PHP-FPM, MySQL). Infra scripts are in `infra/`.

- Web root: `/var/www/html`
- Database: `wordpress` (user `wp_user`, localhost)
- WP-CLI is installed at `/usr/local/bin/wp`; run it as `sudo -u www-data wp ...` from `/var/www/html`

## SSH to the VM

```bash
cd infra && ./sshCurrentVM.sh
```

## Daily health checks

The VM is a `Standard_B2pts_v2` (1 GB RAM + 2 GB swap file), so memory is the thing to watch.
`sar` (sysstat) records memory, swap, load and memory pressure every minute and keeps 28 days in
`/var/log/sysstat/` (set up by `infra/create-webserver.sh`).

One command from WSL in `infra/` (uses the host in `sshCurrentVM.sh`):

```bash
host=$(grep -o 'dave@[^ ]*' sshCurrentVM.sh)
ssh -o StrictHostKeyChecking=no $host '
uptime; sudo journalctl --list-boots --no-pager | tail -3
free -m; swapon --show; df -h /
echo "== OOM kills"; sudo journalctl -k --since "-1 day" --no-pager | grep -iE "oom|killed process"
echo "== swapping (pages/s) today"; sar -W | tail -3
echo "== memory today"; sar -r | tail -4
echo "== swap today"; sar -S | tail -4
echo "== memory pressure today (%smem, %fmem)"; sar -q MEM | tail -4
echo "== worst minute for memory pressure"; sar -q MEM | grep -v -e Average -e "^$" | sort -k5 -gr | head -2
echo "== php-fpm at max_children"; sudo grep -c "max_children" /var/log/php8.5-fpm.log
echo "== nginx 5xx since log rotated (daily)"; sudo awk "\$9 ~ /^5/" /var/log/nginx/access.log | wc -l
echo "== biggest processes"; ps -eo rss,comm --sort=-rss | head -6'
```

For a previous day, add `-f /var/log/sysstat/saDD` to `sar` (`DD` = day of month).

What is normal and when to act:

| Check | Normal | Act if |
|---|---|---|
| `sar -q MEM` `%smem` (some processes waiting for memory) | 0-1% | regularly over ~5% |
| `sar -q MEM` `%fmem` (all processes waiting) | 0 | any sustained value |
| `free -m` available | 200-300 MB | regularly under 100 MB |
| Swap used | under ~300 MB | steadily over 500 MB |
| `sar -W` pswpin/s, pswpout/s | near 0 | regularly over ~10 |
| OOM kills | none | any |
| Reboots (`--list-boots`) | only ones you did | any you didn't |
| php-fpm `max_children` warnings | 0 | rising each day |
| nginx 5xx | 0 | more than a handful |
| Disk `/` | ~20% | over 80% |

Memory pressure is the main signal: swap in use with ~0% pressure is just idle pages parked on disk and is fine.
If memory is the problem, change `--size` in `infra/infra.azcli` to `Standard_B2pls_v2` (4 GB, same Arm image) and rebuild.

Baseline 3 minutes after boot on 2026-11-21: 296 MB available, 90 MB swap, MySQL ~230 MB, disk 20%.

## Back up before a WordPress update

On the VM:

```bash
ts=$(date +%Y%m%d-%H%M)
sudo mysqldump --single-transaction wordpress > ~/wp-db-$ts.sql
sudo tar czf ~/wp-files-$ts.tgz -C /var/www html
ls -lh ~/wp-*$ts*
```

`sudo mysqldump` needs no password because MySQL root uses socket auth.

Copy the backups off the VM (from WSL; `<vm_host>` is the host in `infra/sshCurrentVM.sh`):

```bash
scp '<vm_host>:~/wp-*' <local_backup_dir>/
```

## Restore

On the VM:

```bash
sudo mysql wordpress < ~/wp-db-<timestamp>.sql
sudo rm -rf /var/www/html && sudo tar xzf ~/wp-files-<timestamp>.tgz -C /var/www
```

## Let's Encrypt rate limit

Each `infra/infra.azcli` build gets a new certificate for `hoverflylagoons.co.uk` + `www`. Let's Encrypt allows
5 certificates for the same set of names per 7 days. Check how many were issued recently before rebuilding:

```bash
curl -s 'https://api.certspotter.com/v1/issuances?domain=hoverflylagoons.co.uk&include_subdomains=true&expand=dns_names&expand=issuer' \
  | jq -r '.[] | [.not_before, .issuer.friendly_name, (.dns_names|join(","))] | @tsv'
```

Only count certificates with exactly `hoverflylagoons.co.uk,www.hoverflylagoons.co.uk`. Cert Spotter is up to date;
crt.sh can lag by weeks. `certbot certificates` on the VM only shows that VM's own certificate.

## Updating

For a major version jump, update WordPress core first and check the site. Then update the plugins and the theme.
