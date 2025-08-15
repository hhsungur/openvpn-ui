#!/bin/bash
# sendmail.sh - Standalone OpenVPN configuration email sender
# Usage: bash sendmail.sh <username> (optional)<email_address>

# Setup logging
LOG_FILE="/var/log/openvpn-sendmail.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

if [ $# -lt 1 ]; then
    log_error "Usage: $0 <username> (optional)[email_address]"
        log_error "Example: $0 john.doe (optional)john.doe@company.com"
    exit 1
fi

CERT_NAME=$1
CRT_PATH="/etc/openvpn/pki/issued/${CERT_NAME}.crt"

if [ $# -ge 2 ]; then
    EMAIL_ADDRESS=$2
    echo "Using provided email address: $EMAIL_ADDRESS"
else
        # --- Extract email from cert into EMAIL_ADDRESS ---
        if [ -f "$CRT_PATH" ]; then
            EMAIL_ADDRESS="$(openssl x509 -in "$CRT_PATH" -noout -email 2>/dev/null | head -n1 || true)"
        else
        echo "Certificate file not found at $CRT_PATH"
        fi
fi

log_message "=== Email Sending Started ==="
log_message "Username: $CERT_NAME"
log_message "Email: $EMAIL_ADDRESS"

# Configuration - adjust these paths to match your setup
OPENVPN_DIR="/etc/openvpn"  # Adjust this path
OVPN_FILE="$OPENVPN_DIR/clients/$CERT_NAME.ovpn"
OVPN_FILENAME=$(basename "$OVPN_FILE")


# Check if OpenVPN file exists
log_message "Looking for OVPN file: $OVPN_FILE"
if [[ ! -f "$OVPN_FILE" ]]; then
    log_error "OpenVPN file not found: $OVPN_FILE"
    log_message "Available files in directory:"
    ls -la "$OPENVPN_DIR/clients/" 2>/dev/null | tee -a "$LOG_FILE" || log_error "Cannot access clients directory"
    exit 1
fi

# Check msmtp availability
if ! command -v msmtp >/dev/null 2>&1; then
    log_error "msmtp not found. Please install msmtp."
    exit 1
fi

if [[ ! -f /etc/msmtprc ]]; then
    log_error "msmtp configuration not found at /etc/msmtprc"
    exit 1
fi

log_message "msmtp configuration found"

## Get certificate expiry (if available in easyrsa environment)
#CERT_EXPIRE_DAYS=${EASYRSA_CERT_EXPIRE:-365}
#EXPIRY_DATE=$(date -d "+${CERT_EXPIRE_DAYS} days" '+%Y-%m-%d' 2>/dev/null || echo "Not specified")

log_message "Creating email content..."

# Create email content
EMAIL_CONTENT=$(cat << EOF
To: $EMAIL_ADDRESS
Subject: VPN Configuration - $CERT_NAME
Content-Type: multipart/mixed; boundary="ovpn-boundary"

--ovpn-boundary
Content-Type: text/plain; charset=utf-8

Dear Employee,

We have successfully generated your VPN access configuration for Company network resources.
You can follow these instructions to import your VPN file.

INSTALLATION INSTRUCTIONS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. DOWNLOAD CLIENT SOFTWARE:
   • Windows: https://openvpn.net/community-downloads/
   • iOS: "OpenVPN Connect" from App Store
   • Android: "OpenVPN for Android" from Google Play

2. IMPORT CONFIGURATION:
   • Save the attached ${OVPN_FILENAME} file to your device
   • Open your OpenVPN client application
   • Import/Add the .ovpn configuration file
   • The profile "${CERT_NAME}" will appear in your client

3. CONNECT TO VPN:
   • Select the "${CERT_NAME}" profile
   • Click Connect
   • Enter your credentials when prompted

For technical assistance, please contact: it@company.com

Best regards,
IT Team

---
This is an automated message. Please do not reply directly to this email.

--ovpn-boundary
Content-Type: application/x-openvpn-profile
Content-Disposition: attachment; filename="$OVPN_FILENAME"
Content-Transfer-Encoding: base64

$(base64 "$OVPN_FILE")

--ovpn-boundary--
EOF
)

# Log email size
EMAIL_SIZE=$(echo "$EMAIL_CONTENT" | wc -c)
log_message "Email content size: $EMAIL_SIZE bytes"

# Send email
log_message "Sending email to $EMAIL_ADDRESS..."

if echo "$EMAIL_CONTENT" | msmtp "$EMAIL_ADDRESS" 2>&1 | tee -a "$LOG_FILE"; then
    log_message "✅ Email sent successfully to $EMAIL_ADDRESS"
    echo "SUCCESS: OpenVPN configuration sent to $EMAIL_ADDRESS"
    exit 0
else
    log_error "❌ Failed to send email to $EMAIL_ADDRESS"

    # Additional debugging
    log_message "Running msmtp debug test..."
    echo "test email" | msmtp --debug "$EMAIL_ADDRESS" 2>&1 | tee -a "$LOG_FILE" || true

    echo "FAILED: Could not send email. Check logs: $LOG_FILE"
    exit 1
fi