package SMT::Utils;

use strict;
use warnings;

use Config::IniFiles;
use DBI qw(:sql_types);
use Fcntl;
use IO::File;

use Locale::gettext ();
use POSIX ();     # Needed for setlocale()

POSIX::setlocale(&POSIX::LC_MESSAGES, "");

our @ISA = qw(Exporter);
our @EXPORT = qw(__ printLog);


#
# read db values from the smt configuration file,
# open the database and returns the database handle
#
sub db_connect
{
    my $cfg = new Config::IniFiles( -file => "/etc/smt.conf" );
    if(!defined $cfg)
    {
        # FIXME: is die correct here?
        die sprintf(__("Cannot read the SMT configuration file: %s"), @Config::IniFiles::errors);
    }
    
    my $config = $cfg->val('DB', 'config');
    my $user   = $cfg->val('DB', 'user');
    my $pass   = $cfg->val('DB', 'pass');
    if(!defined $config || $config eq "")
    {
        # FIXME: is die correct here?
        die __("Invalid Database configuration. Missing value for DB/config.");
    }
     
    my $dbh    = DBI->connect($config, $user, $pass, {RaiseError => 1, AutoCommit => 1});

    return $dbh;
}

#
# localization function
#
sub __ 
{
    my $msgid = shift;
    my $package = caller;
    my $domain = "smt";
    return Locale::gettext::dgettext ($domain, $msgid);
}

#
# lock file support
#

#
# try to create a lock file in /var/run/
# Return TRUE on success, otherwise FALSE
#
sub openLock
{
    my $progname = shift;
    my $pid = $$;
    
    my $path = "/var/run/$progname.pid";
    
    if( -e $path )
    {
        return 0;
    }
    sysopen(LOCK, $path, O_WRONLY | O_EXCL | O_CREAT, 0640) or return 0;
    print LOCK "$pid";
    close LOCK;

    return 1;
}

#
# try to remove the lockfile
# Return TRUE on success, otherwise false
#
sub unLock
{
    my $progname = shift;
    my $pid = $$;
    
    my $path = "/var/run/$progname.pid";
    
    if(! -e $path )
    {
        return 1;
    }
    
    open(LOCK, "< $path") or return 0;
    my $dp = <LOCK>;
    close LOCK;
    
    if($dp ne "$pid")
    {
        return 0;
    }
    
    my $cnt = unlink($path);
    return 1 if($cnt == 1);
    
    return 0;
}

#
# Return an array with ($url, $guid, $secret)
#
sub getLocalRegInfos
{
    my $uri    = "";
    
    open(FH, "< /etc/suseRegister.conf") or die sprintf(__("Cannot open /etc/suseRegister.conf: %s"), $!);
    while(<FH>)
    {
        if($_ =~ /^url\s*=\s*(\S*)\s*/ && defined $1 && $1 ne "")
        {
            $uri = $1;
            last;
        }
    }
    close FH;
    
    if(!defined $uri || $uri eq "")
    {
        die __("Cannot read URL from /etc/suseRegister.conf");
    }
    
    my $cfg = new Config::IniFiles( -file => "/etc/smt.conf" );
    if(!defined $cfg)
    {
        # FIXME: is die correct here?
        die sprintf(__("Cannot read the SMT configuration file: %s"), @Config::IniFiles::errors);
    }
    
    my $user   = $cfg->val('NU', 'NUUser');
    my $pass   = $cfg->val('NU', 'NUPass');
    if(!defined $user || $user eq "" || 
       !defined $pass || $pass eq "")
    {
        # FIXME: is die correct here?
        die __("Cannot read Mirror Credentials from SMT configuration file.");
    }

    return ($uri, $user, $pass);  
}


#
# You can provide a parameter in seconds from 1970-01-01 00:00:00
# If you do not provide a parameter the current time is used.
#
# return the timestamp in database format
# YYY-MM-DD hh:mm:ss
#
sub getDBTimestamp
{
    my $time = shift || time;
    
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($time);
    $year += 1900;
    $mon +=1;
    my $timestamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year,$mon,$mday, $hour,$min,$sec);
    return $timestamp;
}


#
# open logfile
#
sub openLog
{
    my $logfile = shift || "/dev/null";
    
    my $LOG;
    open($LOG, ">> $logfile") or die "Cannot open logfile '$logfile': $!";
    if($logfile ne "/dev/null")
    {
        $LOG->autoflush(1);
    }
    return $LOG;
}

sub printLog
{
    my $LOG      = shift;
    my $category = shift;
    my $message  = shift;
    my $doprint  = shift || 1;
    my $dolog    = shift || 1;

    if($doprint)
    {
        if(lc($category) eq "error")
        {
            print STDERR "$message\n";
        }
        else
        {
            print "$message\n";
        }
    }
    
    if($dolog && defined $LOG)
    {
        my ($package, $filename, $line) = caller;
        foreach (split(/\n/, $message))
        {
            print $LOG getDBTimestamp()." $package - [$category]  $_\n";
        }
    }
    return;
}


1;
