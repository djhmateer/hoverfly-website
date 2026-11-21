# hoverfly-website

WordPress site on an Azure VM (Ubuntu, nginx, PHP-FPM, MySQL). Infra scripts are in `infra/`.

- Web root: `/var/www/html`
- Database: `wordpress` (user `wp_user`, localhost)
- WP-CLI is installed at `/usr/local/bin/wp`; run it as `sudo -u www-data wp ...` from `/var/www/html`

## SSH to the VM

```bash
cd infra && ./sshCurrentVM.sh
```

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
