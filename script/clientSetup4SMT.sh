#! /bin/sh

WGET=/usr/bin/wget
CURL=/usr/bin/curl
OPENSSL=/usr/bin/openssl
CREHASH=/usr/bin/c_rehash
ZMDINIT=/etc/init.d/novell-zmd
SRCONF=/etc/suseRegister.conf
CP=/bin/cp
CAT=/bin/cat
CHMOD=/bin/chmod
GREP=/usr/bin/grep
RM=/bin/rm

SSLDIR=/etc/ssl/certs/
ZMDSSLDIR=/etc/zmd/trusted-certs/

REGURL=$1

if [ -z "$REGURL" ]; then
	echo "Missing registration URL. Abort."
    echo ""
    echo "Usage: $0 <registration URL>"
    echo "       configures a SLE10 client to register against a different registration server"
    echo ""
    echo "Example: $0 https://smt.example.com/center/regsvc"
	exit 1;
fi

if ! echo $REGURL | grep "^https" > /dev/null ; then
    echo "The registration URL must be a HTTPS URL. Abort."
    exit 1
fi

if [ ! -x $OPENSSL ]; then
	echo "openssl command not found. Abort.";
	exit 1;
fi

if [ ! -x $CREHASH ]; then
	echo "c_rehash command not found. Abort.";
	exit 1;
fi

if [ ! -x $CP ]; then
	echo "cp command not found. Abort.";
	exit 1;
fi

if [ ! -x $CAT ]; then
	echo "cat command not found. Abort.";
	exit 1;
fi

if [ ! -x $GREP ]; then
	echo "grep command not found. Abort.";
	exit 1;
fi

if [ ! -x $RM ]; then
	echo "rm command not found. Abort.";
	exit 1;
fi

if [ ! -x $CHMOD ]; then
	echo "chmod command not found. Abort.";
	exit 1;
fi

CERTURL=`echo "$REGURL" | awk -F/ '{print "https://" $3 "/smt.crt"}'`
TEMPFILE=`mktemp /tmp/smt.crt.XXXXXX`

if [ -x $WGET ]; then
	$WGET  --no-verbose -q --no-check-certificate --output-document $TEMPFILE $CERTURL
	if [ $? -ne 0 ]; then
		echo "Download failed. Abort.";
		exit 1;
	fi
elif [ -x $CURL ]; then
	$CURL  -s -S --insecure --output $TEMPFILE $CERTURL 
        if [ $? -ne 0 ]; then
                echo "Download failed. Abort.";
                exit 1;
        fi
else
	echo "Binary to download the certificate not found. Please install curl or wget. Abort."
	exit 1;
fi

$OPENSSL x509 -in $TEMPFILE -text -noout

read -p "Do you accept this certificate? [y/n] " -n 1 YN

echo "";
if [ "$YN" != "Y" -a "$YN" != "y" ]; then
	echo "Abort.";
	exit 1;
fi

$CP $TEMPFILE $SSLDIR/smt.pem
$CHMOD 0644 $SSLDIR/smt.pem
$CP $TEMPFILE $ZMDSSLDIR/smt.cer
$CHMOD 0644 $ZMDSSLDIR/smt.cer

$CREHASH $SSLDIR > /dev/null

if [ -x $ZMDINIT ]; then
	$ZMDINIT restart > /dev/null
fi

SRCTMP=`mktemp /tmp/suseRegister.conf.XXXXXX`


$CAT $SRCONF | $GREP -v "^url" > $SRCTMP
$CP $SRCONF ${SRCONF}-`date '+%x'` 
echo "url=$REGURL" > $SRCONF
$CAT $SRCTMP >> $SRCONF
$RM $SRCTMP

echo "Client setup finished."
