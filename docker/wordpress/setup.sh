#!/bin/sh
# One-shot WordPress provisioning, run by the wp-setup service (wp-cli image).
# Safe to re-run: `docker compose up wp-setup` re-applies the settings below.
set -eu

cd /var/www/html

if ! wp core is-installed 2>/dev/null; then
  echo "[wp-setup] installing WordPress at ${WP_URL}"
  wp core install \
    --url="${WP_URL}" \
    --title="${WP_TITLE}" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASSWORD}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --skip-email
else
  echo "[wp-setup] WordPress already installed"
fi

# The plugin folder is the wp-sitewitness repository, bind-mounted read-only
if ! wp plugin is-active wp-sitewitness; then
  wp plugin activate wp-sitewitness
fi

# Point the plugin at the sitewitness-agent container. The source id and its
# HMAC secret come from the Supabase `sources` table (root .env).
if [ -n "${SITEWITNESS_SOURCE_ID:-}" ]; then
  wp option update sitewitness_webhook_url "${SITEWITNESS_AGENT_URL}/api/ingest/${SITEWITNESS_SOURCE_ID}"
else
  echo "[wp-setup] SITEWITNESS_SOURCE_ID not set: webhook URL left as is (Settings > SiteWitness)"
fi

if [ -n "${SITEWITNESS_HMAC_SECRET:-}" ]; then
  wp option update sitewitness_webhook_secret "${SITEWITNESS_HMAC_SECRET}" >/dev/null
  echo "[wp-setup] webhook secret set"
else
  echo "[wp-setup] SITEWITNESS_HMAC_SECRET not set: webhook secret left as is"
fi

wp option update sitewitness_schedule "${SITEWITNESS_SCHEDULE:-daily}"

echo "[wp-setup] done: $(wp core version) at ${WP_URL} (admin: ${WP_ADMIN_USER})"
