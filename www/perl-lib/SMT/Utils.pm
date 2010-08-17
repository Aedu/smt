package SMT::Utils;

use strict;
use warnings;

use Log::Log4perl qw(get_logger :levels);
use Config::IniFiles;
use DBI qw(:sql_types);
use Fcntl qw(:DEFAULT);
use IO::File;
use File::Basename;
use IPC::Open3;  # for executeCommand

use MIME::Lite;  # sending eMails
use Net::SMTP;   # sending eMails via smtp relay

use Locale::gettext ();
use POSIX ();     # Needed for setlocale()
use User::pwent;
use Sys::GRP;
use RPMMD::Config;

POSIX::setlocale(&POSIX::LC_MESSAGES, "");

use English;

our @ISA = qw(Exporter);
our @EXPORT = qw(__ __N LOG_ERROR LOG_WARN LOG_INFO1 LOG_INFO2 LOG_DEBUG LOG_DEBUG2 LOG_DEBUG3);

use constant LOG_ERROR  => 0x0001;
use constant LOG_WARN   => 0x0002;
use constant LOG_INFO1  => 0x0004;
use constant LOG_INFO2  => 0x0008;
use constant LOG_DEBUG  => 0x0010;
use constant LOG_DEBUG2 => 0x0020;
use constant LOG_DEBUG3 => 0x0040;

use constant TOK2STRING => {
                            1  => "error",
                            2  => "warn",
                            4  => "info",
                            8  => "info",
                            12 => "info", # info1 + info2
                            16 => "debug",
                            32 => "debug",
                            64 => "debug"
                           };



=head1 NAME

SMT::Utils - Utility library

=head1 SYNOPSIS

  use SMT::Utils;

=head1 DESCRIPTION

Utility library.

=head1 METHODS

=over 4

=item getSMTConfig([path])

Read SMT config file and return a Config::IniFiles object.
This function will "die" on error
If I<path> to the configfile is omitted, the default
I</etc/smt.conf> is used.

=cut
#
# there is no need to close $cfg . Config::IniFiles
# read the file into the memory and close the handle self
#
sub getSMTConfig
{
    my $filename = shift || "/etc/smt.conf";

    my $cfg = new Config::IniFiles( -file => $filename );
    if(!defined $cfg)
    {
        # die is ok here.
        die sprintf(__("Cannot read the SMT configuration file: %s"), @Config::IniFiles::errors);
    }
    return $cfg;
}

=item smt2RpmmdConfig([cfg])

Sets RPMMD::Config options to corresponding values form smt.conf.
Call this function whenever you use RPMMD modules.

See also getSMTConfig.

=cut

sub smt2RpmmdConfig
{
    my $smtcfg = shift or getSMTConfig();
    my $rcfg = RPMMD::Config->instance();
    
    $rcfg->set('NET', 'userAgent',  $smtcfg->val('LOCAL', 'UserAgent'))   if ($smtcfg->val('LOCAL', 'UserAgent'));
    $rcfg->set('NET', 'httpProxy',  $smtcfg->val('LOCAL', 'HTTPProxy'))   if ($smtcfg->val('LOCAL', 'HTTPProxy'));
    $rcfg->set('NET', 'httpsProxy', $smtcfg->val('LOCAL', 'HTTPSProxy'))  if ($smtcfg->val('LOCAL', 'HTTPSProxy'));
    $rcfg->set('NET', 'ftpProxy',   $smtcfg->val('LOCAL', 'FTPProxy'))    if ($smtcfg->val('LOCAL', 'FTPProxy'));
    $rcfg->set('NET', 'proxyUser',  $smtcfg->val('LOCAL', 'ProxyUser'))   if ($smtcfg->val('LOCAL', 'ProxyUser'));
    $rcfg->set('NET', 'noProxy',    $smtcfg->val('LOCAL', 'NoProxy'))     if ($smtcfg->val('LOCAL', 'NoProxy'));
}


=item db_connect([cfg])

Read database values from the smt configuration file,
open the database and returns the database handle

If cfg is omitted, I<getSMTConfig> is called.

=cut
sub db_connect
{
    my $cfg = shift || getSMTConfig();

    my $config = $cfg->val('DB', 'config');
    my $user   = $cfg->val('DB', 'user');
    my $pass   = $cfg->val('DB', 'pass');
    if(!defined $config || $config eq "")
    {
        # should be ok to die here
        die __("Invalid Database configuration. Missing value for DB/config.");
    }

    my $dbh    = DBI->connect($config, $user, $pass, {RaiseError => 1, AutoCommit => 1});

    return $dbh;
}

=item __()

Localization function

=cut
sub __
{
    my $msgid = shift;
    my $package = caller;
    my $domain = "smt";
    return Locale::gettext::dgettext ($domain, $msgid);
}

=item __N()

Localization function for plural forms.

=cut

sub __N
{
    my ($msgid, $msgidpl, $n) = @_;
    my $package = caller;
    my $domain = "smt";
    return Locale::gettext::dngettext ($domain, $msgid, $msgidpl, $n);
}

#
# lock file support
#

=item openLock($progname)

Try to create a lock file in /var/run/smt/$progname.pid .
Return TRUE on success, otherwise FALSE.

=cut
sub openLock
{
    my $progname = shift;
    my $pid = $$;

    my $dir  = "/var/run/smt";
    my $path = "$dir/$progname.pid";

    return 0 if( !-d $dir || !-w $dir );

    if( -e $path )
    {
        # check if the process is still running

        my $oldpid = "";

        open(LOCK, "< $path") and do {
            $oldpid = <LOCK>;
            close LOCK;
        };

        chomp($oldpid);

        if( ! -e "/proc/$oldpid/cmdline")
        {
            # pid does not exists; remove lock
            unlink $path;
        }
        else
        {
            my $cmdline = "";
            open(CMDLINE, "< /proc/$oldpid/cmdline") and do {
                $cmdline = <CMDLINE>;
                close CMDLINE;
            };

            if($cmdline !~ /$progname/)
            {
                # this pid is a different process; remove the lock
                unlink $path;
            }
            else
            {
                # process still running
                return 0;
            }
        }
    }

    sysopen(LOCK, $path, O_WRONLY | O_EXCL | O_CREAT, 0640) or return 0;
    print LOCK "$pid";
    close LOCK;

    return 1;
}

=item unLock($progname)

Try to remove the lockfile
Return TRUE on success, otherwise false

=cut
sub unLock
{
    my $progname = shift;
    my $pid = $$;

    my $path = "/var/run/smt/$progname.pid";

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

=item unLockAndExit($progname, $exitcode, $log, $loglevel)

Try to remove the lockfile, log to $log on failure.
Exit program with $exitCode (regardless of success or
failure of the unlock)

=cut
sub unLockAndExit
{
    my ($progname, $exitcode) = @_;
    my $log = undef;
    eval { $log = get_logger(); }; # we may not have Log4perl initialized here

    if (!SMT::Utils::unLock($progname))
    {
        $log->fatal("Cannot remove lockfile.") if ($log);
        print STDERR  __("Cannot remove lockfile.")."\n";
    }
    exit $exitcode;
}

=item getLocalRegInfos()

Return an array with ($NCCurl, $NUUser, $NUPassword)

=cut
sub getLocalRegInfos
{
    my $uri    = "";

    my $cfg = getSMTConfig;

    my $user   = $cfg->val('NU', 'NUUser');
    my $pass   = $cfg->val('NU', 'NUPass');
    if(!defined $user || $user eq "" ||
       !defined $pass || $pass eq "")
    {
        # FIXME: is die correct here?
        die __("Cannot read Mirror Credentials from SMT configuration file.");
    }

    $uri = $cfg->val('NU', 'NURegUrl');
    if(!defined $uri || $uri !~ /^https/)
    {
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
    }
    return ($uri, $user, $pass);
}

=item getSMTGuid()

Return guid of the SMT server. If it not exists
die and request a registration call.

=cut

sub getSMTGuid
{
    my $guid   = "";
    my $secret = "";
    my $CREDENTIAL_DIR = "/etc/zypp/credentials.d";
    my $CREDENTIAL_FILE = "NCCcredentials";
    my $GUID_FILE = "/etc/zmd/deviceid";
    my $SECRET_FILE = "/etc/zmd/secret";
    my $fullpath = $CREDENTIAL_DIR."/".$CREDENTIAL_FILE;

    if(!-d "$CREDENTIAL_DIR" || ! -e "$fullpath")
    {
        die "Credential file does not exist. You need to register the SMT server first.";
    }

    #
    # read credentials from NCCcredentials file
    #
    open(CRED, "< $fullpath") or do {
        die("Cannot open file $fullpath for read: $!\n");
    };
    while(<CRED>)
    {
        if($_ =~ /username\s*=\s*(.*)$/ && defined $1 && $1 ne "")
        {
            $guid = $1;
	    last;
        }
    }
    close CRED;
    return $guid;
}


=item getDBTimestamp($time)

You can provide a parameter in seconds from 1970-01-01 00:00:00 as $time.
If you do not provide a parameter the current time is used.

Returns the timestamp in database format "YYY-MM-DD hh:mm:ss"

=cut
sub getDBTimestamp
{
    my $time = shift || time;

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($time);
    $year += 1900;
    $mon +=1;
    my $timestamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year,$mon,$mday, $hour,$min,$sec);
    return $timestamp;
}

=item timeFormat($time)

If you provide $time in seconds, this function returns the interval
in a human readable format "X Day(s) HH:MM:SS"

=cut
sub timeFormat
{
    my $time = shift;

    $time = 1 if($time < 1);

    my $sec = $time % 60;

    $time = int($time / 60);

    my $min = $time % 60;

    $time = int($time / 60);

    my $hour = $time % 24;

    $time = int($time /24);

    my $str = "";

    $str .= "$time ".__("Day(s)")." " if ($time > 0);

    $str .= sprintf("%02d:%02d:%02d", $hour, $min, $sec);
    return $str;
}


=item byteFormat($size)

Returns $size (size in bytes) as human readable format, like:

 640.8 KB
 3.2 MB
 1.9 GB

=cut
sub byteFormat
{
    my $size = shift;
    my $div = 1024;

    return "$size Bytes" if($size < $div);

    $size = $size / $div;
    return sprintf("%.2f KB", $size) if($size < $div);

    $size = $size / $div;
    return sprintf("%.2f MB", $size) if($size < $div);

    $size = $size / $div;
    return sprintf("%.2f GB", $size) if($size < $div);

    $size = $size / $div;
    return sprintf("%.2f TB", $size);
}

# translate vblevel for screen messages
sub vblevel2log4perl4Screen
{
  my $vblevel = shift;
  
  return $DEBUG if($vblevel & (LOG_INFO2|LOG_DEBUG|LOG_DEBUG2|LOG_DEBUG3));
  return $INFO  if($vblevel & (LOG_INFO1));
  return $WARN  if($vblevel & (LOG_WARN));
  return $ERROR;
}

# translate vblevel for file messages
sub vblevel2log4perl4File
{
  my $vblevel = shift;
  
  return $TRACE if($vblevel & (LOG_DEBUG|LOG_DEBUG2|LOG_DEBUG3));
  return $INFO  if($vblevel & (LOG_INFO1|LOG_INFO2));
  return $WARN  if($vblevel & (LOG_WARN));
  return $ERROR;
}

=item cleanPath(@pathlist)

Concatenate all parts of the pathlist, remove double slashes and return
the result as an absolute path.

=cut
sub cleanPath
{
    return "" if(!exists $_[0] || !defined $_[0]);
    my $path = join( "/", @_);
    die "Path not defined" if(! defined $path || $path eq "");
    $path =~ s/\/\.?\/+/\//g;
    return $path;
}

=item setLogBehavior($new_behavior)

Defines the logging behavior that replaces all other settings.
This is required by YaST SCR (e.g., using STDOUT is not allowed).

 setLogBehavior ({'doprint' => 0})

Allowed parameters:

=over

=item setLogBehavior($logbehavior)

Suppresses printing logs to STDOUT

=back

=cut
my $log_behavior = {};

sub setLogBehavior ($) {
    my $new_behavior = shift || {};

    if (defined $new_behavior->{'doprint'}) {
	$log_behavior->{'doprint'} = $new_behavior->{'doprint'};
    }
}


=item sendMailToAdmins($subject, $message [, $attachements])

Sends an eMail with the passed subject and content to the administrators defined in smt.conf as "reportEmail".
This function will do nothing if no eMail address is specified

=cut
sub sendMailToAdmins
{
    my $subject = shift;
    my $message = shift;
    my $attachments = shift;
    if (! defined $subject)  { return; }
    if (! defined $message)  { return; }

    my $cfg = getSMTConfig;

    my $getReportEmail = $cfg->val('REPORT', 'reportEmail');
    my @reportEmailList = split(/,/, $getReportEmail);
    my @addressList = ();
    foreach my $val (@reportEmailList)
    {
        $val =~ s/^\s*//;
        $val =~ s/\s*$//;

        push @addressList, $val;
    }
    if (scalar(@addressList) < 1 )  { return; }
    my $reportEmailTo = join(', ', @addressList);

    # read config for smtp relay
    my %relay = ();
    $relay{'server'}    = $cfg->val('REPORT', 'mailServer');
    $relay{'port'}      = $cfg->val('REPORT', 'mailServerPort');
    $relay{'user'}      = $cfg->val('REPORT', 'mailServerUser');
    $relay{'password'}  = $cfg->val('REPORT', 'mailServerPassword');
    my $reportEmailFrom = $cfg->val('REPORT', 'reportEmailFrom');

    if (! defined $reportEmailFrom  || $reportEmailFrom eq '')
    { $reportEmailFrom = "$ENV{'USER'}\@".getFQDN(); }

    # create the mail config
    my $mtype = 'sendmail';   # default to send eMail directly

    if (defined $relay{'server'}  &&  $relay{'server'} ne '')
    {
        # switch to smtp if a relay is defined
        $mtype = 'smtp';

        # make sure the port is valid
        if (! defined $relay{'port'} || $relay{'port'} !~ /^\d+$/ )
        {
            $relay{'port'} = '';
        }

        $relay{'Relay'} = "$relay{'server'}";
        if ($relay{'port'} ne '')
        {
            $relay{'Relay'} .= ":$relay{'port'}";
        }

        if (defined $relay{'user'}  &&  $relay{'user'} ne '')
        {
            # make sure we have a password - even if empty
            if (! defined $relay{'password'} )
            {
                $relay{'password'} = '';
            }
        }
        else
        {
            # if no authentication is needed - set user to undef
            $relay{'user'} = undef;
        }

    }

    # create the message
    my $msg = MIME::Lite->new( 'From'    => $reportEmailFrom,
                               'To'      => $reportEmailTo,
                               'Subject' => $subject,
                               'Type'    => 'multipart/mixed'
                             );

    # attach message as mail body
    $msg->attach( 'Type' => 'TEXT',
                  'Data' => $message
                );


    if (defined $attachments  &&  scalar(keys %{$attachments} ) > 0 )
    {
        foreach my $filename ( sort keys %{$attachments})
        {
            $msg->attach( 'Type'        =>'text/csv',
                          'Filename'    => $filename,
                          'Data'        => ${$attachments}{$filename},
                          'Disposition' => 'attachment'
                 );
        }
    }

    if ($mtype  eq  'sendmail')
    {
        # send message via sendmail (-t automatically scans for the recipients in the header)
        $msg->send($mtype, "/usr/lib/sendmail -t -oi ");
    }
    else
    {
        # send message via NET::SMTP
        if (defined $relay{'user'})
        {
            # with user authentication
            $msg->send('smtp', $relay{'Relay'}, 'AuthUser' => $relay{'user'}, 'AuthPass' => $relay{'password'}  );
        }
        else
        {
            # or withour user authentication
            $msg->send($mtype, $relay{'Relay'});
        }
    }

    return;
}

=item getFQDN()

Return the full qualified domain name (host.domain.top)

=cut

sub getFQDN
{
    my $hostname = `/bin/hostname --short 2>/dev/null`;
    my $domain = `/bin/hostname --domain 2>/dev/null`;
    my $fqdn = "";
    chomp($hostname);
    chomp($domain);
    if(defined $hostname && $hostname ne "")
    {
        $fqdn = $hostname;
    }
    else
    {
        $fqdn = "linux";
    }
    if(defined $domain && $domain ne "")
    {
        $fqdn .= ".$domain";
    }
    else
    {
        $fqdn .= ".site";
    }
    return $fqdn;
}



=item getProxySettings()

Return ($httpProxy, $httpsProxy, $noProxy, $proxyUser)

If no values are found these values are undef

=cut
sub getProxySettings
{
    my $cfg = getSMTConfig;

    my $httpProxy  = $cfg->val('LOCAL', 'HTTPProxy');
    my $httpsProxy = $cfg->val('LOCAL', 'HTTPSProxy');
    my $proxyUser  = $cfg->val('LOCAL', 'ProxyUser');
    my $noProxy    = $cfg->val('LOCAL', 'NoProxy');

    $httpProxy  = undef if(defined $httpProxy  && $httpProxy =~ /^\s*$/);
    $httpsProxy = undef if(defined $httpsProxy && $httpsProxy =~ /^\s*$/);
    $proxyUser  = undef if(defined $proxyUser  && $proxyUser =~ /^\s*$/);
    $noProxy    = undef if(defined $noProxy    && $noProxy =~ /^\s*$/);

    if(! defined $httpProxy)
    {
        if(exists $ENV{http_proxy} && defined $ENV{http_proxy} && $ENV{http_proxy} =~ /^http/)
        {
            $httpProxy = $ENV{http_proxy};
        }
    }

    if(! defined $httpsProxy)
    {
        if(exists $ENV{https_proxy} && defined $ENV{https_proxy} && $ENV{https_proxy} =~ /^http/)
        {
            # required for Crypt::SSLeay HTTPS Proxy support
            $httpsProxy = $ENV{https_proxy};
        }
    }

    if(! defined $noProxy)
    {
        if(exists $ENV{no_proxy} && defined $ENV{no_proxy} && $ENV{no_proxy} !~ /^\s*$/)
        {
            $noProxy = $ENV{no_proxy};
        }
        elsif(exists $ENV{NO_PROXY} && defined $ENV{NO_PROXY} && $ENV{NO_PROXY} !~ /^\s*$/)
        {
            $noProxy = $ENV{NO_PROXY};
        }
    }

    # strip trailing /
    $httpsProxy =~ s/\/*$// if(defined $httpsProxy);
    $httpProxy  =~ s/\/*$// if(defined $httpProxy);

    if(! defined $proxyUser)
    {
        if($UID == 0 && -r "/root/.curlrc")
        {
            # read /root/.curlrc
            open(RC, "< /root/.curlrc") or return ($httpProxy, $httpsProxy, undef);
            while(<RC>)
            {
                if($_ =~ /^\s*proxy-user\s*=\s*"(.+)"\s*$/ && defined $1 && $1 ne "")
                {
                    $proxyUser = $1;
                }
                elsif($_ =~ /^\s*--proxy-user\s+"(.+)"\s*$/ && defined $1 && $1 ne "")
                {
                    $proxyUser = $1;
                }
            }
            close RC;
        }
        elsif($UID != 0 &&
              exists $ENV{HOME} && defined  $ENV{HOME} &&
              $ENV{HOME} ne "" && -r "$ENV{HOME}/.curlrc")
        {
            # read ~/.curlrc
            open(RC, "< $ENV{HOME}/.curlrc") or return ($httpProxy, $httpsProxy, undef);
            while(<RC>)
            {
                if($_ =~ /^\s*proxy-user\s*=\s*"(.+)"\s*$/ && defined $1 && $1 ne "")
                {
                    $proxyUser = $1;
                }
                elsif($_ =~ /^\s*--proxy-user\s+"(.+)"\s*$/ && defined $1 && $1 ne "")
                {
                    $proxyUser = $1;
                }
            }
            close RC;
        }
    }
    else
    {
        if($proxyUser =~ /^\s*"?(.+)"?\s*$/ && defined $1)
        {
            $proxyUser = $1;
        }
        else
        {
            $proxyUser = undef;
        }
    }

    return ($httpProxy, $httpsProxy, $noProxy, $proxyUser);
}


=item createUserAgent([%options])

Return a UserAgent object using some defaults. %options are passed to
the UserAgent constructor.

=cut
sub createUserAgent
{
    my %opts = @_;

    require SMT::Curl;

    my $ua = SMT::Curl->new(%opts);

    my $cfg = getSMTConfig;
    my $userAgentString  = $cfg->val('LOCAL', 'UserAgent', "LWP::UserAgent/$LWP::VERSION");
    $userAgentString  = "LWP::UserAgent/$LWP::VERSION" if( $userAgentString eq "");
    $ua->agent($userAgentString);

    return $ua;
}

=item getFile($userAgent, $srcUrl, $target)

Simple file getter which uses $userAgent to get file from $srcUrl to local
file with path $target.

Returns true on success, false if something goes wrong.

=cut

# TODO make a simple Downloader with getFile & doesFileExist functions, with logging, etc. Detto in perl-rpmmd

sub getFile
{
    my ($userAgent, $srcUrl, $target) = @_;

    # make sure the target dir exists
    &File::Path::mkpath(dirname($target));

    my $redirects = 0;
    my $ret = 0;
    my $response;

    do
    {
        eval
        {
            $response = $userAgent->get( $srcUrl, ':content_file' => $target );
        };
        if($@)
        {
            $ret = 0;
            last;
        }

        if ( $response->is_redirect )
        {
            $redirects++;
            if($redirects > 15)
            {
                $ret = 0;
                last
            }

            my $newuri = $response->header("location");
            chomp($newuri);
            $srcUrl = $newuri;
        }
        elsif($response->is_success)
        {
            $ret = 1;
        }
    } while($response->is_redirect);

    return $ret;
}


=item doesFileExist($userAgent, $srcUrl)

Issue a head request to find out whether remote file $srcUrl exitst.

Returns true on success, false if something goes wrong.

=cut

sub doesFileExist
{
    my ($userAgent, $srcUrl) = @_;

    my $redirects = 0;
    my $tries = 0;
    my $ret = 0;
    my $response;

    do
    {
        eval
        {
            $response = $userAgent->head($srcUrl);
        };
        if($@)
        {
            $ret = 0;
            $tries++;
        }
    
        if ( $response->is_redirect )
        {
            $redirects++;
            $tries = 4 if ($redirects > 15);
	    my $newuri = $response->header("location");
	    chomp($newuri);
            $srcUrl = $newuri;
        }
        elsif ( $response->is_success )
        {
            $ret = 1;
            $tries = 4;
        }
        else 
        {
            $tries++;
        }
    } while ($tries < 4);

    return $ret;
}

=item dropPrivileges

If current user id is I<root>, drop the privileges and switch to user I<smt>.
If the current user id B<is not> I<root>, this function return without any action.

Returns false in case a privileges drop should happen, but cannot. Otherwise true.

=cut

sub dropPrivileges
{
    my $euid = POSIX::geteuid();
    return 0 if( !defined $euid );

    # if we do not run as root, we do not need to drop privileges
    return 1 if( $euid != 0 );

    my $user = 'smt';
    eval
    {
        my $cfg = getSMTConfig();
        $user = $cfg->val('LOCAL', 'smtUser');
    };
    if(!defined $user || $user eq "")
    {
        $user = 'smt';
    }

    # if the customer want to run smt commands under root permissions
    # we let him do this
    return 1 if("$user" eq "root");

    my $pw = getpwnam($user) || return 0;

    $GID  = $pw->gid(); # $GID only accepts a single number according to perlvar
    $EGID = $pw->gid();
    if( Sys::GRP::initgroups($user, $pw->gid()) != 0 )
    {
        return 0;
    }
    POSIX::setuid( $pw->uid() ) || return 0;

    # test is euid is correct
    return 0 if( POSIX::geteuid() != $pw->uid() );

    $ENV{'HOME'} = $pw->dir();
    if( chdir( $pw->dir() ) )
    {
        $ENV{'PWD'} = $pw->dir();
    }

    return 1;
}

=item getSaveUri($uriString)

Create a URI string save for logging or printing (by removin username and password)
from the URI. Returns the stripped down URI

=cut
sub getSaveUri
{
    my $uri = shift;
    my $saveuri = URI->new($uri);
    if ( $saveuri->scheme ne "file" )
    {
        $saveuri->userinfo(undef);
    }
    return $saveuri->as_string();
}

=item executeCommand($options, $command, @arguments)

Executes command using open3 function, logs the result and returns
the exit code, and normal and error output of the command.

If the command fails to execute, the return value is (-1, undef, undef).
Otherwise ($exitcode, $out, $err) is returned, where $exitcode is the value
returned by the command, and $out/$err is it's normal/error output.

Options:

=over 4

=item input

Optional input to pass on to the command.

=back

=cut

sub executeCommand
{
    my ($opt, $command, @arguments) = @_;

    my $log = undef;
    my $out = undef;
    eval
    {
      # we may not have Log4perl initialized here
      $log = get_logger();
      $out = get_logger('userlogger');
    };
    
    my $output = "";
    my $error = "";
    my $exitcode = 0;

    my $lang     = $ENV{LANG};
    my $language = $ENV{LANGUAGE};

    $lang = undef if($lang && $lang =~ /^en_/);
    $language = undef if($language && $language =~ /^en_/);

    if(!defined $command || !-x $command)
    {
        $log->error(sprintf("Invalid command '%s'",$command)) if($log);
        $out->error(sprintf("Invalid command '%s'",$command)) if($out);
        return -1;
    }

    # set lang to en_US to get output in english.
    $ENV{LANG}     = "en_US" if(defined $lang);
    $ENV{LANGUAGE} = "en_US" if(defined $language);

    $log->debug("Executing '$command ".join(" ", @arguments)."'") if($log);

    my $pid = open3(\*IN, \*OUT, \*ERR, $command, @arguments) or do
    {
        $ENV{LANG}     = $lang if(defined $lang);
        $ENV{LANGUAGE} = $language  if(defined $language);
        my $err = $!;
        $log->error(sprintf("Could not execute command %s %s: %s", $command, join(" ", @arguments), $err)) if($log);
        $out->error(sprintf("Executeing command '%s' failed: %s", $command, $err)) if($out);
        return -1;
    };

    print IN $opt->{input} if(defined $opt->{input});
    close IN;

    while (<OUT>)
    {
        $output .= "$_";
    }
    while (<ERR>)
    {
        $error .= "$_";
    }
    close OUT;
    close ERR;

    waitpid $pid, 0;

    chomp($output);
    chomp($error);

    $ENV{LANG}     = $lang if(defined $lang);
    $ENV{LANGUAGE} = $language if(defined $language);

    $exitcode = ($? >> 8);

    $log->debug(sprintf("Command returned %d %s", $exitcode, ($error ? ": $error" : ''))) if($log);
    $log->trace("Command output:\n$output") if ($log);

    return ($exitcode, $error, $output);
}


=item findCatalogs($dbh, $target, \@product_ids, $groupid)

Return a hash reference with all repositories belong to the
provided products in the specified group and target.

Options:

=over 4

=item $dbh

A database handle

=item $target

A string with the target (e.g. sle-11-x86_64)

=item \@product_ids

A array reference with the product ids.

=item $groupid

The id of the used group. Default is "1", the default group.

=back

Returns:

Return a hash reference with all repositories belong to the
provided products in the specified group and target.

=over 4

=back

=cut

sub findCatalogs
{
  my $dbh        = shift;
  my $target     = shift;
  my $productids = shift;
  my $groupid    = shift || 1;
  my $log = get_logger();
  
  my $result = {};
  my $statement ="";
  
  if(!$dbh)
  {
    $log->error("No database handle");
    return $result;
  }
  if( !$productids || @{$productids} == 0)
  {
    # This should not happen
    $log->error("No productids found");
    return $result;
  }
  
  $log->debug("TARGET: $target");
  
  foreach my $id (@{$productids})
  {
    # check if this product should not return any catalog (CATALOGID == NULL)
    $statement = sprintf("SELECT PRODUCTDATAID from ProductCatalogs WHERE PRODUCTDATAID = %s AND GROUPID = %s AND CATALOGID IS NULL",
                         $dbh->quote($id), $dbh->quote($groupid));
    $log->debug("STATEMENT: $statement");
    my $res = $dbh->selectcol_arrayref($statement);
    
    next if( @{$res} > 0); #skip this product
    
    $statement = sprintf("SELECT PRODUCTDATAID, CATALOGID, OPTIONAL from ProductCatalogs WHERE PRODUCTDATAID = %s AND GROUPID = %s",
                         $dbh->quote($id), $dbh->quote($groupid));
    $log->debug("STATEMENT: $statement");
    $res = $dbh->selectall_hashref($statement, "CATALOGID");
    
    if( $groupid > 1 && {keys %{$res}} == 0)
    {
      # not found; fallback to default group 1
      $statement = sprintf("SELECT PRODUCTDATAID, CATALOGID, OPTIONAL from ProductCatalogs WHERE PRODUCTDATAID = %s AND GROUPID = %s",
                           $dbh->quote($id), $dbh->quote(1));
      $log->debug("STATEMENT: $statement");
      $res = $dbh->selectall_hashref($statement, "CATALOGID");
    }
    my @quoted_cids = ();
    foreach my $cid (keys %{$res})
    {
      push @quoted_cids, $dbh->quote($cid);
    }
    
    $statement =  "SELECT CATALOGID, NAME, DESCRIPTION, TARGET, LOCALPATH, CATALOGTYPE, STAGING, DOMIRROR from Catalogs ";
    $statement .= "WHERE CATALOGID IN (".join(',', @quoted_cids).") and (TARGET IS NULL ";
    if($target)
    {
      $statement .= sprintf("OR TARGET=%s", $dbh->quote($target));
    }
    $statement .= ")";
    
    $log->debug("STATEMENT: $statement");

    my $res2 = $dbh->selectall_hashref($statement, "CATALOGID");
    foreach my $cid (keys %{$res2})
    {
      foreach my $key (keys %{$res2->{$cid}})
      {
        $result->{$cid}->{$key} = $res2->{$cid}->{$key};
      }
      $result->{$cid}->{'OPTIONAL'} = $res->{$cid}->{'OPTIONAL'};
    }
  }
  
  $log->debug("RESULT: ".Data::Dumper->Dump([$result]));
  
  return $result;
}

sub getGroupIDforGUID
{
  my $dbh  = shift;
  my $guid = shift;
  my $log = get_logger();
  my $groupid = 1;
  
  my $statement = sprintf("SELECT GROUPID from Clients where GUID = %s",
                          $dbh->quote($guid));
  $log->debug("STATEMENT: $statement");
  eval
  {
    my $sqlres = $dbh->selectcol_arrayref($statement);
    if(exists $sqlres->[0] && defined $sqlres->[0])
    {
      $groupid = int($sqlres->[0]);
    }
  };
  if($@)
  {
    $log->error("DBERROR: ".$dbh->errstr);
  }
  return $groupid;
}

sub groupnameToID
{
  my $dbh       = shift;
  my $groupname = shift;
  my $log       = get_logger();
  my $groupid   = 1;
  
  return $groupid if(!$groupname);
  
  my $statement = sprintf("SELECT ID from Groups where NAME = %s LIMIT 1",
                          $dbh->quote($groupname));
  $log->debug("STATEMENT: $statement");
  eval
  {
    my $sqlres = $dbh->selectcol_arrayref($statement);
    if(exists $sqlres->[0] && defined $sqlres->[0])
    {
      $groupid = int($sqlres->[0]);
    }
  };
  if($@)
  {
    $log->error("DBERROR: ".$dbh->errstr);
  }
  return $groupid;
}


=back

=head1 AUTHOR

mc@suse.de, jdsn@suse.de, rhafer@suse.de, locilka@suse.cz

=head1 COPYRIGHT

Copyright 2007, 2008, 2009 SUSE LINUX Products GmbH, Nuernberg, Germany.

=cut

1;
