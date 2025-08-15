#!/bin/bash
#VERSION 1.4 by d3vilh@github.com aka Mr. Philipp. Updated with Easyrsa 3 support.
# Exit immediately if a command exits with a non-zero status.
set -e

# .ovpn file path
CERT_NAME=$1
CERT_IP=$2
CERT_PASS=$3
# These VARS shoud be in your ENV before running certgen: TFA_NAME, ISSUER, EASYRSA_CERT_EXPIRE, EASYRSA_REQ_EMAIL, EASYRSA_REQ_COUNTRY, EASYRSA_REQ_PROVINCE, EASYRSA_REQ_CITY, EASYRSA_REQ_ORG, EASYRSA_REQ_OU

EASY_RSA=$(grep -E "^EasyRsaPath\s*=" ../openvpn-ui/conf/app.conf | cut -d= -f2 | tr -d '"' | tr -d '[:space:]')
OPENVPN_DIR=$(grep -E "^OpenVpnPath\s*=" ../openvpn-ui/conf/app.conf | cut -d= -f2 | tr -d '"' | tr -d '[:space:]')
echo "EasyRSA path: $EASY_RSA OVPN path: $OPENVPN_DIR"
OVPN_FILE_PATH="$OPENVPN_DIR/clients/$CERT_NAME.ovpn"
OATH_SECRETS="$OPENVPN_DIR/clients/oath.secrets"   # 2FA secrets file

# Validate username and check for duplicates
if  [[ -z $CERT_NAME ]]; then
    echo 'Name cannot be empty. Exiting...'
    exit 1
elif [[ -f $OVPN_FILE_PATH ]]; then
    echo "User with name $CERT_NAME already exists under openvpn/clients. Exiting..."
    exit 1
fi

export EASYRSA_BATCH=1 # see https://superuser.com/questions/1331293/easy-rsa-v3-execute-build-ca-and-gen-req-silently

echo 'Patching easy-rsa.3.1.1 openssl-easyrsa.cnf...'
sed -i '/serialNumber_default/d' "$EASY_RSA/openssl-easyrsa.cnf"

echo 'Generate client certificate...'
echo -e "Will use following parameters: \nEASYRSA_CERT_EXPIRE: $EASYRSA_CERT_EXPIRE\nEASYRSA_REQ_EMAIL: $EASYRSA_REQ_EMAIL" #\nEASYRSA_REQ_COUNTRY: $EASYRSA_REQ_COUNTRY\nEASYRSA_REQ_PROVINCE: $EASYRSA_REQ_PROVINCE\nEASYRSA_REQ_CITY: $EASYRSA_REQ_CITY\nEASYRSA_REQ_ORG: $EASYRSA_REQ_ORG\nEASYRSA_REQ_OU: $EASYRSA_REQ_OU"
echo -e "EasyRSA VARS will be used:\n$(cat $EASY_RSA/vars)"

# Copy easy-rsa variables
cd $EASY_RSA

# Generate certificates
if  [[ -z $CERT_PASS ]]; then
    echo 'Without password...'
    ./easyrsa --batch --req-cn="$CERT_NAME" --days="$EASYRSA_CERT_EXPIRE" --req-email="$EASYRSA_REQ_EMAIL" gen-req "$CERT_NAME" nopass
    #subject="/C=$EASYRSA_REQ_COUNTRY/ST=$EASYRSA_REQ_PROVINCE/L=\"$EASYRSA_REQ_CITY\"/O=\"$EASYRSA_REQ_ORG\"/OU=\"$EASYRSA_REQ_OU\""
else
    echo 'With password...'
    # See https://stackoverflow.com/questions/4294689/how-to-generate-an-openssl-key-using-a-passphrase-from-the-command-line
    # ... and https://stackoverflow.com/questions/22415601/using-easy-rsa-how-to-automate-client-server-creation-process
    # ... and https://github.com/OpenVPN/easy-rsa/blob/master/doc/EasyRSA-Advanced.md
    (echo -e '\n') | ./easyrsa --batch --req-cn="$CERT_NAME" --days="$EASYRSA_CERT_EXPIRE" --req-email="$EASYRSA_REQ_EMAIL" --passin=pass:"${CERT_PASS}" --passout=pass:"${CERT_PASS}" gen-req "$CERT_NAME"
    #subject="/C=$EASYRSA_REQ_COUNTRY/ST=$EASYRSA_REQ_PROVINCE/L=\"$EASYRSA_REQ_CITY\"/O=\"$EASYRSA_REQ_ORG\"/OU=\"$EASYRSA_REQ_OU\""
fi

# Sign request. Bypass "yes" with export EASYRSA_BATCH=1
./easyrsa sign-req client "$CERT_NAME"
# Fix for /name in index.txt

# Check if 2FA was specified. If not - set to none.
if [ -z "$TFA_NAME" ]; then
    TFA_NAME="none"
fi

echo "Fixing Database..."
sed -i'.bak' "$ s/$/\/name=${CERT_NAME}\/LocalIP=${CERT_IP}\/2FAName=${TFA_NAME}/" $EASY_RSA/pki/index.txt
echo "Database fixed:"
tail -1 $EASY_RSA/pki/index.txt
# Certificate properties
CA="$(cat $EASY_RSA/pki/ca.crt )"
CERT="$(cat $EASY_RSA/pki/issued/${CERT_NAME}.crt)"
KEY="$(cat $EASY_RSA/pki/private/${CERT_NAME}.key)"
TLS_AUTH="$(cat $EASY_RSA/pki/ta.key)"

echo 'Fixing permissions for pki/issued...'
chmod +r $EASY_RSA/pki/issued

echo 'Generating .ovpn file...'

# Create the .ovpn file using awk (works well on Alpine/BusyBox)
awk -v ca="$CA" -v cert="$CERT" -v key="$KEY" -v tls_auth="$TLS_AUTH" '
BEGIN { in_ca=0; in_cert=0; in_key=0; in_tls=0 }
/<ca>/ {
    print "<ca>"
    print ca
    print "</ca>"
    in_ca=1
    next
}
/<\/ca>/ {
    in_ca=0
    next
}
/<cert>/ {
    print "<cert>"
    print cert
    print "</cert>"
    in_cert=1
    next
}
/<\/cert>/ {
    in_cert=0
    next
}
/<key>/ {
    print "<key>"
    print key
    print "</key>"
    in_key=1
    next
}
/<\/key>/ {
    in_key=0
    next
}
/<tls-crypt>/ {
    print "<tls-crypt>"
    print tls_auth
    print "</tls-crypt>"
    in_tls=1
    next
}
/<\/tls-crypt>/ {
    in_tls=0
    next
}
!in_ca && !in_cert && !in_key && !in_tls { print }
' "$OPENVPN_DIR/config/client.conf" > "$OVPN_FILE_PATH"

echo -e "OpenVPN Client configuration successfully generated!\nCheckout openvpn-server/clients/$CERT_NAME.ovpn"

# Check if $TFA_NAME was specified and not equal to "none". then create 2FA and QR code
if [[ ! -z $TFA_NAME ]] && [[ $TFA_NAME != "none" ]]; then
    echo -e "Generating 2FA ...\nName: $TFA_NAME\nIssuer: $TFA_ISSUER"

    # Userhash. Random 30 chars
    USERHASH=$(head -c 10 /dev/urandom | openssl sha256 | cut -d ' ' -f2 | cut -b 1-30)

    # Base32 secret from oathtool output
    BASE32=$(oathtool --totp -v "$USERHASH" | grep Base32 | awk '{print $3}')

    # QRCODE STRING
    QRSTRING="otpauth://totp/$TFA_ISSUER:$TFA_NAME?secret=$BASE32"

    # QR code for user to pass to Google Authenticator or OpenVPN-UI
    echo "User String for QR:"
    echo $QRSTRING

    /opt/scripts/qrencode "$QRSTRING" > $OPENVPN_DIR/clients/$CERT_NAME.png

    # New string for secrets file
    echo "oath.secrets entry for BackEnd:"
    echo "$TFA_NAME:$USERHASH" | tee -a $OATH_SECRETS

    else
    echo 'No 2FA specified. exiting'

fi

if [[ -n "$EASYRSA_REQ_EMAIL" ]]; then
    echo "Scheduling OpenVPN configuration email..."

    # Launch email script in background
    nohup /opt/scripts/sendmail.sh "$CERT_NAME" "$EASYRSA_REQ_EMAIL" > /dev/null 2>&1 &
    EMAIL_PID=$!

    echo "Email will be sent in background (PID: $EMAIL_PID)"
    echo "Check email logs: /var/log/openvpn-sendmail.log"
else
    echo "No email address provided. Skipping email notification."
fi