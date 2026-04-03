#!/bin/bash
set -e

COMPOSE="docker compose"
DOMAIN="${DOMAIN:-n8n.hackartist.io}"
EMAIL="${CERTBOT_EMAIL:-admin@hackartist.io}"
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

echo "=== Local Infra Init ==="

# Check if certificate already exists in the volume
if $COMPOSE run --rm --entrypoint "" certbot test -f "$CERT_PATH" 2>/dev/null; then
    echo "Certificate for $DOMAIN already exists."
    echo "Starting all services..."
    $COMPOSE up -d
    echo "Done. https://$DOMAIN is ready."
    exit 0
fi

echo "No certificate found for $DOMAIN. Bootstrapping..."

# Step 1: Start nginx with HTTP-only config for ACME challenge
echo "[1/4] Starting nginx (HTTP only)..."
$COMPOSE run -d --name nginx-init \
    -p 80:80 \
    -v "$(pwd)/nginx/nginx-http-only.conf:/etc/nginx/nginx.conf:ro" \
    -v "certbot-webroot:/var/www/certbot:ro" \
    nginx

# Wait for nginx to be ready
sleep 2

# Step 2: Request certificate
echo "[2/4] Requesting certificate for $DOMAIN..."
$COMPOSE run --rm certbot certonly \
    --webroot --webroot-path=/var/www/certbot \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos --no-eff-email

# Step 3: Stop temporary nginx
echo "[3/4] Stopping temporary nginx..."
docker stop nginx-init && docker rm nginx-init

# Step 4: Start all services with full SSL config
echo "[4/4] Starting all services with SSL..."
$COMPOSE up -d

echo ""
echo "=== Setup complete ==="
echo "https://$DOMAIN is ready."
echo ""
echo "To renew certificates later, run:"
echo "  $COMPOSE run --rm certbot renew && $COMPOSE exec nginx nginx -s reload"
