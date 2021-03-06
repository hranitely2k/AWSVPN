#!/bin/sh
# Please define your own values for those variables
yum install -y --enablerepo=epel pwgen

IPSEC_PSK=weiquee6weiquaiQuieH
MYSQL_PASSWORD=$(pwgen -B 12 1)
RAD_PASSWORD=$(pwgen -B 12 1)
HOSTNAME=$(hostname)
RADSRV_PASSWORD=$(pwgen -B 12 1)
 
# Those two variables will be found automatically
#PRIVATE_IP=`wget -q -O - 'http://instance-data/latest/meta-data/local-ipv4'`
PRIVATE_IP=`ifconfig | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p'`
 
#the following does not work in VPC
#PUBLIC_IP=`wget -q -O - 'http://instance-data/latest/meta-data/public-ipv4'`
#
# use http://169.254.169.254/latest/meta-data/network/interfaces/macs/06:79:3f:b2:49:20/ipv4-associations/ instead but depends on mac address :-(
#
PUBLIC_IP=`wget -q -O - 'checkip.amazonaws.com'`
 
yum install -y --enablerepo=epel openswan xl2tpd mysql-server freeradius freeradius-mysql freeradius-utils net-tools radiusclient-ng

#Secure mysql
service mysqld start
/usr/libexec/mysql55/mysqladmin -u root password $MYSQL_PASSWORD
cat > /root/.my.cnf <<EOF
[client]
user=root
password=$MYSQL_PASSWORD
EOF

#Radius
mysql -uroot -p$MYSQL_PASSWORD -e "create database radius default character set utf8; grant all privileges on radius.* to radius@localhost identified by '$RAD_PASSWORD'; grant all privileges on radius.* to radius@'%' identified by '$RAD_PASSWORD';"
mysql -uroot -p$MYSQL_PASSWORD radius < /etc/raddb/sql/mysql/schema.sql
sed -i 's|radpass|'$RAD_PASSWORD'|g' /etc/raddb/sql.conf
sed -i 's|testing123|'$RADSRV_PASSWORD'|g' /etc/raddb/clients.conf
wget https://www.dmosk.ru/files/dictionary.microsoft -O /usr/share/freeradius/dictionary.microsoft
echo "127.0.0.1 $HOSTNAME" >> /etc/hosts
sed -i 's|#[[:space:]]$INCLUDE sql.conf|        $INCLUDE sql.conf|g' /etc/raddb/radiusd.conf
sed -i 's|#[[:space:]]sql|        sql|g' /etc/raddb/sites-enabled/default


#Radiusclient
ln -s /etc/radiusclient-ng /etc/radiusclient
sed -i 's|bindaddr|#bindaddr|g' /etc/radiusclient-ng/radiusclient.conf
echo "localhost $RADSRV_PASSWORD" >>/etc/radiusclient-ng/servers
cp /usr/share/radiusclient-ng/dictionary.merit /etc/radiusclient-ng/
wget https://www.dmosk.ru/files/dictionary.microsoft -O /etc/radiusclient-ng/dictionary.microsoft
cat > /etc/radiusclient/dictionary <<EOF
INCLUDE /etc/radiusclient-ng/dictionary.microsoft
INCLUDE /etc/radiusclient-ng/dictionary.merit
EOF

 
cat > /etc/ipsec.conf <<EOF
version 2.0
 
config setup
	dumpdir=/var/run/pluto/
	nat_traversal=yes
	virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:25.0.0.0/8,%v6:fd00::/8,%v6:fe80::/10
	oe=off
	protostack=netkey
	nhelpers=0
	interfaces=%defaultroute

conn vpnpsk
	auto=add
	left=$PRIVATE_IP
	leftid=$PUBLIC_IP
	leftsubnet=$PRIVATE_IP/32
	leftnexthop=%defaultroute
	leftprotoport=17/1701
	rightprotoport=17/%any
	right=%any
	rightsubnetwithin=0.0.0.0/0
	forceencaps=yes
	authby=secret
	pfs=no
	type=transport
	auth=esp
	ike=3des-sha1
	phase2alg=3des-sha1
	dpddelay=30
	dpdtimeout=120
	dpdaction=clear
EOF
 
cat > /etc/ipsec.secrets <<EOF
$PUBLIC_IP %any : PSK "$IPSEC_PSK"
EOF
 
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701
 
;debug avp = yes
;debug network = yes
;debug state = yes
;debug tunnel = yes

[lns default]
ip range = 10.0.10.2-10.0.10.250
local ip = 10.0.10.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
;ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
 
cat > /etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
crtscts
idle 1800
mtu 1280
mru 1280
lock
connect-delay 5000
plugin radius.so
plugin radattr.so
EOF
 
cat > /etc/ppp/chap-secrets <<EOF
# Secrets for authentication using CHAP
# client server secret IP addresses
EOF
 
iptables -t nat -A POSTROUTING -s 10.0.10.0/24 -o eth0 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward
 
iptables-save > /etc/iptables.rules

mkdir -p /etc/network/if-pre-up.d
cat > /etc/network/if-pre-up.d/iptablesload <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
echo 1 > /proc/sys/net/ipv4/ip_forward
exit 0
EOF

service ipsec start
service xl2tpd start
service radiusd start
chkconfig ipsec on
chkconfig xl2tpd on
chkconfig radiusd on
chkconfig mysqld on


