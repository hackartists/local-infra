#!/bin/bash
set -e

PR_NUMBER="${1:?Usage: $0 <pr-number>}"
DOMAIN="${PR_NUMBER}.pr.ratel.foundation"
PORT="2${PR_NUMBER}"
OUTPUT="nginx/conf.d/pr-${PR_NUMBER}.conf"

cat > "$OUTPUT" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/pr.ratel.foundation/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/pr.ratel.foundation/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://192.168.0.7:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

echo "Generated $OUTPUT for ${DOMAIN} -> 192.168.0.7:${PORT}"
