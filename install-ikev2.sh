#!/bin/sh
# Created by WHMCS-Smarters www.whmcssmarters.com

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SYS_DT=$(date +%F-%T)

exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { exiterr "'apt-get install' failed."; }
conf_bk() { /bin/cp -f "$1" "$1.old-$SYS_DT" 2>/dev/null; }
bigecho() { echo; echo "## $1"; echo; }

PUBLIC_IP=$(dig @resolver1.opendns.com -t A -4 myip.opendns.com +short)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)

echo " Public IP Address: $PUBLIC_IP"

bigecho "Populating apt-get cache..."

export DEBIAN_FRONTEND=noninteractive
apt-get -yq update || exiterr "'apt-get update' failed."

bigecho "VPN setup in progress... Please be patient."


 
sudo apt install strongswan strongswan-pki -yq || exiterr2

echo " Strongswan Installed " 

count=0
APT_LK=/var/lib/apt/lists/lock
PKG_LK=/var/lib/dpkg/lock
while fuser "$APT_LK" "$PKG_LK" >/dev/null 2>&1 \
  || lsof "$APT_LK" >/dev/null 2>&1 || lsof "$PKG_LK" >/dev/null 2>&1; do
  [ "$count" = "0" ] && bigecho "Waiting for apt to be available..."
  [ "$count" -ge "60" ] && exiterr "Could not get apt/dpkg lock."
  count=$((count+1))
  printf '%s' '.'
  sleep 3
done



echo " Making Directories for Certs files " 

if [ -d "~/pki/" ] 
then
    echo "Directory exists and removed "
rm -r ~/pki/
 
else
    echo "Message: Directory ~/pki/ does not exists,So creating..."
fi


mkdir -p ~/pki/ || exiterr " Directories not created "
mkdir -p ~/pki/cacerts/
mkdir -p ~/pki/certs/
mkdir -p ~/pki/private/

chmod 700 ~/pki

ipsec pki --gen --type rsa --size 4096 --outform pem > ~/pki/private/ca-key.pem

ipsec pki --self --ca --lifetime 3650 --in ~/pki/private/ca-key.pem \
    --type rsa --dn "CN=VPN root CA" --outform pem > ~/pki/cacerts/ca-cert.pem

ipsec pki --gen --type rsa --size 4096 --outform pem > ~/pki/private/server-key.pem

ipsec pki --pub --in ~/pki/private/server-key.pem --type rsa \
    | ipsec pki --issue --lifetime 1825 \
        --cacert ~/pki/cacerts/ca-cert.pem \
        --cakey ~/pki/private/ca-key.pem \
        --dn "CN=$PUBLIC_IP" --san "$PUBLIC_IP" \
        --flag serverAuth --flag ikeIntermediate --outform pem \
    >  ~/pki/certs/server-cert.pem

cp -r ~/pki/* /etc/ipsec.d/

bigecho "Installing packages required for setup..."

#apt-get -yq install wget dnsutils openssl \
 # iptables iproute2 gawk grep sed net-tools || exiterr2


# Create IPsec config
#conf_bk "/etc/ipsec.conf"

if [[ -e /etc/ipsec.conf ]]; then

rm /etc/ipsec.conf

echo "Removed ipsec.conf existing file"

fi

cat >> /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=$PUBLIC_IP
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=10.10.10.0/24
    rightdns=8.8.8.8,8.8.4.4
    rightsendcert=never
    eap_identity=%identity
    ike=aes256-sha1-modp1024,aes256gcm16-sha256-ecp521,aes256-sha256-ecp384,aes256-aes128-sha1-modp1024-3des!
    esp=aes256-sha1,aes128-sha256-modp3072,aes256gcm16-sha256,aes256gcm16-ecp384,aes256-sha256-sha1-3des!
EOF

if [[ -e /etc/ipsec.secrets ]]; then
rm /etc/ipsec.secrets
fi

 
cat >> /etc/ipsec.secrets <<EOF
: RSA "server-key.pem"
test : EAP "test123"

EOF


echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

sudo apt-get -yq install iptables-persistent

iptables -P INPUT   ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT
 
iptables -F
iptables -t nat -F
iptables -t mangle -F
 
 
iptables -A INPUT -p udp --dport  500 -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT
 
# forward VPN traffic anywhere
iptables -A FORWARD --match policy --pol ipsec --dir in  --proto esp -s 10.10.10.0/24 -j ACCEPT
iptables -A FORWARD --match policy --pol ipsec --dir out --proto esp -d 10.10.10.0/24 -j ACCEPT
 
iptables -P FORWARD ACCEPT
 
# reduce MTU/MSS values for dumb VPN clients
iptables -t mangle -A FORWARD --match policy --pol ipsec --dir in -s 10.10.10.0/24 -o eth0 -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360
 
# masquerade VPN traffic over eth0 etc.
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -m policy --pol ipsec --dir out -j ACCEPT  # exempt IPsec traffic from masquerading
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE

# Saving Iptables rules
iptables-save > /etc/iptables/rules.v4


bigecho "Updating sysctl settings..."

if ! grep -qs "smarters VPN script" /etc/sysctl.conf; then
  conf_bk "/etc/sysctl.conf"


cat >> /etc/sysctl.conf <<EOF

# Added by smarters VPN script

net.ipv4.ip_forward = 1
net.ipv4.ip_no_pmtu_disc = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.disable_ipv6 = 1
EOF
fi

sysctl -p
ipsec restart

bigecho "Installion Done" 

ca_cert=$(cat /etc/ipsec.d/cacerts/ca-cert.pem)
echo " Username :  test"
echo " Password : test123"
echo " Certificate is " 

echo $ca_cert;
