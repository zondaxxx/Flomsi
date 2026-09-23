#!/usr/bin/env bash
# Start real mail servers on this machine for core/mailcore/tests/live.rs (CI, Ubuntu):
#   Dovecot  IMAP with TLS on 127.0.0.1:10993 and STARTTLS on 10143
#   mailpit  SMTP with STARTTLS on 127.0.0.1:1025, API on 8025
# Both use a throwaway self-signed certificate. Users *@flomsi.test sign in with the
# password below; the mailboxes have Sent, Drafts, Trash and Junk marked special-use and
# no Archive (the tests create it).
set -euo pipefail

DIR=/tmp/flomsi-live
PASSWORD=Live-Pw-9431

sudo apt-get install -y --no-install-recommends dovecot-imapd >/dev/null
sudo systemctl stop dovecot 2>/dev/null || true

rm -rf "$DIR"
mkdir -p "$DIR/mail"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
# Read inside the mailpit container, whatever user it runs as.
chmod 644 "$DIR/key.pem"

for u in roles probe send idle older smoke; do
  echo "$u@flomsi.test:{PLAIN}$PASSWORD"
done >"$DIR/users"

# Dovecot 2.3 wants DH parameters for TLS; the package ships a set.
DH=""
if [ -f /usr/share/dovecot/dh.pem ]; then DH="ssl_dh = </usr/share/dovecot/dh.pem"; fi

cat >"$DIR/dovecot.conf" <<EOF
base_dir = $DIR/run
protocols = imap
listen = 127.0.0.1
log_path = $DIR/dovecot.log
auth_verbose = yes
ssl = required
ssl_cert = <$DIR/cert.pem
ssl_key = <$DIR/key.pem
$DH
disable_plaintext_auth = yes
auth_mechanisms = plain login
first_valid_uid = 500
passdb {
  driver = passwd-file
  args = scheme=PLAIN username_format=%u $DIR/users
}
userdb {
  driver = static
  args = uid=$(id -u) gid=$(id -g) home=$DIR/mail/%u
}
mail_location = maildir:~/Maildir
namespace inbox {
  inbox = yes
  separator = /
  mailbox Sent {
    special_use = \Sent
    auto = subscribe
  }
  mailbox Drafts {
    special_use = \Drafts
    auto = subscribe
  }
  mailbox Trash {
    special_use = \Trash
    auto = subscribe
  }
  mailbox Junk {
    special_use = \Junk
    auto = subscribe
  }
}
service imap-login {
  inet_listener imap {
    address = 127.0.0.1
    port = 10143
  }
  inet_listener imaps {
    address = 127.0.0.1
    port = 10993
    ssl = yes
  }
}
protocol imap {
  mail_max_userip_connections = 100
}
EOF

sudo dovecot -c "$DIR/dovecot.conf"

docker run -d --name mailpit -p 127.0.0.1:1025:1025 -p 127.0.0.1:8025:8025 \
  -v "$DIR:/certs:ro" axllent/mailpit \
  --smtp-tls-cert /certs/cert.pem --smtp-tls-key /certs/key.pem \
  --smtp-require-starttls --smtp-auth-accept-any >/dev/null

for port in 10993 10143 1025 8025; do
  for _ in $(seq 1 30); do
    if nc -z 127.0.0.1 "$port"; then continue 2; fi
    sleep 1
  done
  echo "nothing listens on $port" >&2
  sudo cat "$DIR/dovecot.log" >&2 || true
  docker logs mailpit >&2 || true
  exit 1
done
echo "Dovecot and mailpit are up"
