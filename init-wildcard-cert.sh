#!/bin/bash
set -e

COMPOSE="docker compose"
DOMAIN="pr.ratel.foundation"
WILDCARD="*.$DOMAIN"
EMAIL="${CERTBOT_EMAIL:-admin@hackartist.io}"
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

echo "=== Wildcard Certificate Init for $WILDCARD ==="

# Check if certificate already exists in the volume
if $COMPOSE run --rm --entrypoint "" certbot test -f "$CERT_PATH" 2>/dev/null; then
    echo "Certificate for $WILDCARD already exists."
    echo "To force renew, run:"
    echo "  $COMPOSE run --rm certbot renew --cert-name $DOMAIN --force-renewal"
    exit 0
fi

echo "No certificate found for $WILDCARD. Starting DNS-01 challenge..."
echo ""
echo "NOTE: This requires manual DNS TXT record creation."
echo "You will be prompted to add a TXT record for _acme-challenge.$DOMAIN"
echo ""

# Request wildcard certificate using DNS-01 challenge
$COMPOSE run --rm certbot certonly \
    --manual \
    --preferred-challenges dns \
    -d "$WILDCARD" \
    --email "$EMAIL" \
    --agree-tos --no-eff-email

echo ""
echo "=== Certificate issued ==="
echo "Certificate: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Private key: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo ""
echo "Reloading nginx..."
$COMPOSE exec nginx nginx -s reload 2>/dev/null || echo "nginx not running, skipping reload."

echo ""
echo "Done. *.$DOMAIN is ready for HTTPS."
