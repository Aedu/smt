#! /bin/sh -x

if [ -z "$1" ]; then
    echo "Password required as first parameter"
fi

rpm -Uhv --force OLD/*.rpm

echo "drop database smt;" | mysql -u root -h localhost --password="$1"

echo -e "$1\nsmt\nsystem\nsystem\n" | /usr/lib/SMT/bin/smt-db setup --yast

sed -i 's/^NURegUrl=.*/NURegUrl = https:\/\/secure-www.novell.com\/center\/regsvc\//' /etc/smt.conf

/etc/init.d/smt restart

smt-ncc-sync

