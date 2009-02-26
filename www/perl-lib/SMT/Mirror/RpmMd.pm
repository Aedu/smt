package SMT::Mirror::RpmMd;
use strict;

use LWP::UserAgent;
use URI;
use File::Path;
use File::Find;
use Crypt::SSLeay;
use IO::Zlib;
use Time::HiRes qw(gettimeofday tv_interval);
use Digest::SHA1  qw(sha1 sha1_hex);

use SMT::Mirror::Job;
use SMT::Parser::RpmMd;
use SMT::Utils;

=head1 NAME

SMT::Mirror::RpmMd - mirroring of a rpm metadata repository

=head1 SYNOPSIS

  use SMT::Mirror::RpmMd;

  $mirror = SMT::Mirror::RpmMd->new();
  $mirror->uri( "http://repo.com/10.3" );
  $mirror->localBaseDir("/srv/www/htdocs/repo/");
  $mirror->localRepoDir("RPMMD/10.3/");

  $mirror->mirrorTo();

  $mirror->clean();

=head1 DESCRIPTION

Mirroring of a rpm metadata repository.

The mirror function will not download the same files twice.

In order to clean the repository, that is removing all files
which are not mentioned in the metadata, you can use the clean method:

 $mirror->clean();

=head1 METHODS

=over 4

=item new([%params])

Create a new SMT::Mirror::RpmMd object:

  my $mirror = SMT::Mirror::RpmMd->new();

Arguments are an anonymous hash array of parameters:

=over 4

=item debug <0|1>

Set to 1 to enable debug. 

=item useragent

LWP::UserAgent object to use for this job. Usefull for keep_alive. 

=item dbh

DBI database handle.

=item log

Logfile handle

=item nohardlink

Set to 1 to disable the use of hardlinks. Copy is used instead of it.

=item mirrorsrc

Set to 0 to disable mirroring of source rpms.

=back

=cut

sub new
{
    my $pkgname = shift;
    my %opt   = @_;
    
    my $self  = {};
    $self->{URI}   = undef;

    # starting with / upto  repo/
    $self->{LOCALBASEPATH} = undef;
    
    # catalog Path like LOCALPATH in the DB.
    # e.g. $RCE/SLES11-Updates/sle-11-i586/
    $self->{LOCALREPOPATH}   = undef;


    $self->{JOBS}   = {};
    $self->{VERIFYJOBS}   = {};
    $self->{CLEANLIST} = {};

    $self->{STATISTIC}->{DOWNLOAD} = 0;
    $self->{STATISTIC}->{UPTODATE} = 0;
    $self->{STATISTIC}->{ERROR}    = 0;
    $self->{STATISTIC}->{DOWNLOAD_SIZE} = 0;

    $self->{DEBUG} = 0;
    $self->{LOG}   = undef;
    $self->{DEEPVERIFY}   = 0;
    $self->{DBH} = undef;

    $self->{MIRRORSRC} = 1;
    $self->{NOHARDLINK} = 0;
    
    # Do _NOT_ set env_proxy for LWP::UserAgent, this would break https proxy support
    $self->{USERAGENT}  = (defined $opt{useragent} && $opt{useragent})?$opt{useragent}:SMT::Utils::createUserAgent(keep_alive => 1);


    if(exists $opt{debug} && defined $opt{debug} && $opt{debug})
    {
        $self->{DEBUG} = 1;
    }

    if(exists $opt{dbh} && defined $opt{dbh} && $opt{dbh})
    {
        $self->{DBH} = $opt{dbh};
    }
    
    if(exists $opt{log} && defined $opt{log} && $opt{log})
    {
        $self->{LOG} = $opt{log};
    }
    else
    {
        $self->{LOG} = SMT::Utils::openLog();
    }
    
    if(exists $opt{mirrorsrc} && defined $opt{mirrorsrc} && !$opt{mirrorsrc})
    {
        $self->{MIRRORSRC} = 0;
    }    

    if(exists $opt{nohardlink} && defined $opt{nohardlink} && $opt{nohardlink})
    {
        $self->{NOHARDLINK} = 1;
    }

    bless($self);
    return $self;
}

=item uri([url])

 $mirror->uri( "http://repo.com/10.3" );

 Specify the RpmMd source where to mirror from.

=cut

sub uri
{
    my $self = shift;
    if (@_) { $self->{URI} = shift }
    return $self->{URI};
}

=item localBasePath([path])

Set and get the base path on the local system. Typically starting
with / upto repo/

=cut

sub localBasePath
{
    my $self = shift;
    if (@_) { $self->{LOCALBASEPATH} = shift }
    return $self->{LOCALBASEPATH};
}

=item localRepoPath([path])

Set and get the repository path on the local system. 
E.g. $RCE/SLES11-Updates/sle-11-i586/

=cut

sub localRepoPath
{
    my $self = shift;
    if (@_) { $self->{LOCALREPOPATH} = shift }
    return $self->{LOCALREPOPATH};
}

=item fullLocalRepoPath()

Returns the full path to the repository on the local system. It concatenate
localBasePath() and localRepoPath().

=cut

sub fullLocalRepoPath
{
    my $self = shift;
    
    return SMT::Utils::cleanPath($self->localBasePath(), $self->localRepoPath());
}

=item deepverify()

Enable or disable deepverify mode. 
Returns the current state.

=cut
sub deepverify
{
    my $self = shift;
    if (@_) { $self->{DEEPVERIFY} = shift }
    return $self->{DEEPVERIFY};
}

=item dbh([handle])

Set and get the database handle.

=cut
sub dbh
{
    my $self = shift;
    if (@_) { $self->{DBH} = shift }
    
    return $self->{DBH};
}

=item statistic()

Returns the statistic hash reference. 
Available keys in this has are:

=over 4

=item DOWNLOAD

Number of new files (downloaded, hardlinked or copied)   

=item UPTODATE

Number of files which are up-to-date

=item ERROR

Number of errors.

=item DOWNLOAD_SIZE

Size of files downloaded (in bytes)

=back

=cut

sub statistic
{
    my $self = shift;
    return $self->{STATISTIC};
}


=item debug([0|1])

Enable or disable debug mode for this job.
Returns the current state.

=cut

sub debug
{
    my $self = shift;
    if (@_) { $self->{DEBUG} = shift }
    
    return $self->{DEBUG};
}


=item mirrorTo()

 Start the mirror process.
 Returns the count of errors.

=over 4

=item dryrun

If set to 1, only the metadata are downloaded to a temporary directory and all
files which are outdated are reported. After this is finished, the directory 
containing the metadata is removed.

=back

=cut
sub mirrorTo()
{
    my $self = shift;
    my %options = @_;
    my $dryrun  = 0;
    my $isYum = (ref($self) eq "SMT::Mirror::Yum");
    my $t0 = [gettimeofday] ;
    
    $dryrun = 1 if(exists $options{dryrun} && defined $options{dryrun} && $options{dryrun});

    # reset the counter
    $self->{STATISTIC}->{ERROR}         = 0;
    $self->{STATISTIC}->{UPTODATE}      = 0;
    $self->{STATISTIC}->{DOWNLOAD}      = 0;
    $self->{STATISTIC}->{DOWNLOAD_SIZE} = 0;
    
    my $dest = $self->fullLocalRepoPath();
   
    if ( ! -d $dest )
    {
        printLog($self->{LOG}, "error", "'$dest' does not exist");
        $self->{STATISTIC}->{ERROR} += 1;
        return $self->{STATISTIC}->{ERROR};
    }
    if ( !defined $self->uri() || $self->uri() !~ /^http/ )
    {
        printLog($self->{LOG}, "error", "Invalid URL: ".((defined $self->uri())?$self->uri():"") );
        $self->{STATISTIC}->{ERROR} += 1;
        return $self->{STATISTIC}->{ERROR};
    }
    
    
    # extract the url components to create
    # the destination directory
    # so we save the repo to:
    # $destdir/hostname.com/path
    my $saveuri = URI->new($self->{URI});
    $saveuri->userinfo(undef);
    
    printLog($self->{LOG}, "info", sprintf(__("Mirroring: %s"), $saveuri->as_string )) if(!$isYum);
    printLog($self->{LOG}, "info", sprintf(__("Target:    %s"), $self->fullLocalRepoPath() )) if(!$isYum);

    # get the repository index
    my $job = SMT::Mirror::Job->new(debug => $self->debug(), useragent => $self->{USERAGENT}, log => $self->{LOG},
                                    dbh => $self->{DBH}, nohardlink => $self->{NOHARDLINK} );
    $job->uri( $self->uri() );
    $job->localBasePath( $self->localBasePath() );
    $job->localRepoPath( $self->localRepoPath() );
    $job->localFileLocation( "repodata/repomd.xml" );


    # We expect the data are ok. If repomd.xml does not exist we downlaod everything new
    # which is like deepverify
    my $verifySuccess = 1;
    
    if ( $self->deepverify() && -e $job->fullLocalPath() )
    {
        # a deep verify check is requested 

        my $removeinvalid = 1;
        $removeinvalid = 0 if( $dryrun );

        $verifySuccess = $self->verify( removeinvalid => $removeinvalid, quiet => !$self->debug() );
        
        $self->{STATISTIC}->{ERROR}    = 0;
        $self->{STATISTIC}->{UPTODATE} = 0;
        $self->{STATISTIC}->{DOWNLOAD} = 0;
        $self->{STATISTIC}->{DOWNLOAD_SIZE} = 0;
        
        if ( ! $dryrun )
        {
            # reset deepverify. It was done so we do not need it during mirror again.
            $self->deepverify(0);
        }
    }

    if ( !$job->outdated() && $verifySuccess )
    {
        printLog($self->{LOG}, "info", sprintf(__("=> Finished mirroring '%s' All files are up-to-date."), $saveuri->as_string)) if(!$isYum);
        print "\n" if(!$isYum);
        return 0;
    }
    # else $outdated or verify failed; we must download repomd.xml

    # copy repodata to .repodata 
    # we do not want to damage the repodata until we
    # have them all

    my $metatempdir = SMT::Utils::cleanPath( $job->fullLocalRepoPath(), ".repodata" );

    if( -d "$metatempdir" )
    {
        rmtree($metatempdir, 0, 0);
    }

    &File::Path::mkpath( $metatempdir );

    if( -d $job->fullLocalRepoPath()."/repodata" )
    {
        opendir(DIR, $job->fullLocalRepoPath()."/repodata") or do 
        {
            $self->{STATISTIC}->{ERROR} += 1;
            return $self->{STATISTIC}->{ERROR};
        };
        
        foreach my $entry (readdir(DIR))
        {
            next if ($entry =~ /^\./);
            
            my $fullpath = $job->fullLocalRepoPath()."/repodata/$entry";
            if( -f $fullpath )
            {
                my $success = 0;
                if(!$self->{NOHARDLINK})
                {
                    $success = link( $fullpath, $metatempdir."/$entry" );
                }
                if(!$success)
                {
                    copy( $fullpath, $metatempdir."/$entry" ) or do
                    {
                        printLog($self->{LOG}, "error", "copy metadata failed: $!");
                        $self->{STATISTIC}->{ERROR} += 1;
                        return $self->{STATISTIC}->{ERROR};
                    };
                }
            }
        }
        closedir(DIR);
    }

    my $resource = $job->localFileLocation();
    $job->remoteFileLocation($resource);
    $resource =~ s/repodata/.repodata/;
    $job->localFileLocation($resource);
    
    my $result = $job->mirror();
    $self->{STATISTIC}->{DOWNLOAD_SIZE} += int($job->downloadSize());
    if( $result == 1 )
    {
        $self->{STATISTIC}->{ERROR} += 1;
    }
    elsif( $result == 2 )
    {
        $self->{STATISTIC}->{UPTODATE} += 1;
    }
    else
    {
        if( $dryrun )
        {
            printLog($self->{LOG}, "info",  sprintf("New File [%s]", $job->fillLocalFile()) );
        }
        $self->{STATISTIC}->{DOWNLOAD} += 1;
    }

    $job = SMT::Mirror::Job->new(debug => $self->debug(), useragent => $self->{USERAGENT}, log => $self->{LOG}, 
                                 dbh => $self->{DBH}, nohardlink => $self->{NOHARDLINK} );
    $job->uri( $self->uri() );
    $job->localBasePath( $self->localBasePath() );
    $job->localRepoPath( $self->localRepoPath() );
    $job->remoteFileLocation("repodata/repomd.xml.asc");
    $job->localFileLocation(".repodata/repomd.xml.asc" );

    # if modified return undef, the file might not exist on the server
    # This is ok, signed repodata are not mandatory. So we do not try
    # to mirror it
    if( defined $job->modified(1) )
    {
        $self->{JOBS}->{".repodata/repomd.xml.asc"} = $job;
    }

    $job = SMT::Mirror::Job->new(debug => $self->debug(), useragent => $self->{USERAGENT}, log => $self->{LOG}, 
                                 dbh => $self->{DBH}, nohardlink => $self->{NOHARDLINK} );
    $job->uri( $self->uri() );
    $job->localBasePath( $self->localBasePath() );
    $job->localRepoPath( $self->localRepoPath() );
    $job->remoteFileLocation("repodata/repomd.xml.key");
    $job->localFileLocation(".repodata/repomd.xml.key" );

    # if modified return undef, the file might not exist on the server
    # This is ok, signed repodata are not mandatory. So we do not try
    # to mirror it
    if( defined $job->modified(1) )
    {
        $self->{JOBS}->{".repodata/repomd.xml.key"} = $job;
    }

    
    # we ignore errors. The code work also without this variable set
    # create a hash with filename => checksum
    my $statement = sprintf("SELECT localpath, checksum from RepositoryContentData where localpath like %s",
                            $self->{DBH}->quote($self->fullLocalRepoPath()."%"));
    $self->{EXISTS} = $self->{DBH}->selectall_hashref($statement, 'localpath');
    #printLog($self->{LOG}, "debug", "STATEMENT: $statement \n DUMP: ".Data::Dumper->Dump([$self->{EXISTS}]));
    
    # parse it and find more resources
    my $parser = SMT::Parser::RpmMd->new(log => $self->{LOG});
    $parser->resource($self->fullLocalRepoPath());
    $parser->specialmdlocation(1);
    $parser->parse(".repodata/repomd.xml", sub { download_handler($self, $dryrun, @_)});

    $self->{EXISTS} = undef;

    foreach my $r ( sort keys %{$self->{JOBS}})
    {
        if( $dryrun )
        {
            #
            # we have here only outdated files, so dryrun can display them all as "New File"
            #
            printLog($self->{LOG}, "info",  sprintf("New File [%s]", $self->{JOBS}->{$r}->fullLocalPath() ));
            $self->{STATISTIC}->{DOWNLOAD} += 1;
            
            next;
        }
        
        my $mres = $self->{JOBS}->{$r}->mirror();
        $self->{STATISTIC}->{DOWNLOAD_SIZE} += int($self->{JOBS}->{$r}->downloadSize());
        if( $mres == 1 )
        {
            $self->{STATISTIC}->{ERROR} += 1;
        }
        elsif( $mres == 2 ) # up-to-date should never happen
        {
            $self->{STATISTIC}->{UPTODATE} += 1;
        }
        else
        {
            $self->{STATISTIC}->{DOWNLOAD} += 1;
        }
    }
    
    # if no error happens copy .repodata to repodata
    if(!$dryrun && $self->{STATISTIC}->{ERROR} == 0 && -d $job->fullLocalRepoPath()."/.repodata")
    {
        if( -d $job->fullLocalRepoPath()."/.old.repodata")
        {
            rmtree($job->fullLocalRepoPath()."/.old.repodata", 0, 0);
        }
        my $success = 1;
        if( -d $job->fullLocalRepoPath()."/repodata" )
        {
            $success = rename( $job->fullLocalRepoPath()."/repodata", $job->fullLocalRepoPath()."/.old.repodata");
            if(!$success)
            {
                printLog($self->{LOG}, "error", sprintf(__("Cannot rename directory '%s'"), $job->fullLocalRepoPath()."/repodata"));
                $self->{STATISTIC}->{ERROR} += 1;
            }
        }
        if($success)
        {
            $success = rename( $job->fullLocalRepoPath()."/.repodata", $job->fullLocalRepoPath()."/repodata");
            if(!$success)
            {
                printLog($self->{LOG}, "error", sprintf(__("Cannot rename directory '%s'"), $job->fullLocalRepoPath()."/.repodata"));
                $self->{STATISTIC}->{ERROR} += 1;
            }
        }
    }
    
    if( $dryrun )
    {
        rmtree( $metatempdir, 0, 0 );
        
        printLog($self->{LOG}, "info", sprintf(__("=> Finished dryrun '%s'"), $saveuri->as_string)) if(!$isYum);
        printLog($self->{LOG}, "info", sprintf(__("=> Files to download           : %s"), $self->{STATISTIC}->{DOWNLOAD})) if(!$isYum);
    }
    else
    {
        printLog($self->{LOG}, "info", sprintf(__("=> Finished mirroring '%s'"), $saveuri->as_string)) if(!$isYum);
        printLog($self->{LOG}, "info", sprintf(__("=> Total transferred files     : %s"), $self->{STATISTIC}->{DOWNLOAD})) if(!$isYum);
        printLog($self->{LOG}, "info", sprintf(__("=> Total transferred file size : %s bytes (%s)"), 
                                               $self->{STATISTIC}->{DOWNLOAD_SIZE}, SMT::Utils::byteFormat($self->{STATISTIC}->{DOWNLOAD_SIZE}))) if(!$isYum);
    }
    
    if( int ($self->{STATISTIC}->{UPTODATE}) > 0)
    {
        printLog($self->{LOG}, "info", sprintf(__("=> Files up to date            : %s"), $self->{STATISTIC}->{UPTODATE})) if(!$isYum);
    }
    printLog($self->{LOG}, "info", sprintf(__("=> Errors                      : %s"), $self->{STATISTIC}->{ERROR})) if(!$isYum);
    printLog($self->{LOG}, "info", sprintf(__("=> Mirror Time                 : %s"), SMT::Utils::timeFormat(tv_interval($t0)))) if(!$isYum);
    print "\n" if(!$isYum);

    return $self->{STATISTIC}->{ERROR};
}

=item clean()

Deletes all files not referenced in the rpmmd resource chain

=cut
sub clean()
{
    my $self = shift;
    my $isYum = (ref($self) eq "SMT::Mirror::Yum");
    
    my $t0 = [gettimeofday] ;

    if ( ! -d $self->fullLocalRepoPath() )
    { 
        printLog($self->{LOG}, "error", sprintf(__("Destination '%s' does not exist"), $self->fullLocalRepoPath() ));
        return;
    }

    printLog($self->{LOG}, "info", sprintf(__("Cleaning:         %s"), $self->fullLocalRepoPath() ) ) if(!$isYum);

    # algorithm
    
    find ( { wanted =>
             sub
             {
                 if ( $File::Find::dir !~ /\/headers/ && -f $File::Find::name )
                 { 
                     my $name = SMT::Utils::cleanPath($File::Find::name);

                     $self->{CLEANLIST}->{$name} = 1;
                 }
             }
             , no_chdir => 1 }, $self->fullLocalRepoPath() );

    my $parser = SMT::Parser::RpmMd->new(log => $self->{LOG});
    $parser->resource($self->fullLocalRepoPath());
    $parser->parse("/repodata/repomd.xml", sub { clean_handler($self, @_)});
    
    my $path = SMT::Utils::cleanPath($self->fullLocalRepoPath(), "/repodata/repomd.xml");
    
    delete $self->{CLEANLIST}->{$path} if (exists $self->{CLEANLIST}->{$path});
    delete $self->{CLEANLIST}->{$path.".asc"} if (exists $self->{CLEANLIST}->{$path.".asc"});;
    delete $self->{CLEANLIST}->{$path.".key"} if (exists $self->{CLEANLIST}->{$path.".key"});;

    my $cnt = 0;
    foreach my $file ( keys %{$self->{CLEANLIST}} )
    {
        printLog($self->{LOG}, "debug", "Delete: $file") if ($self->debug());
        $cnt += unlink $file;
        
        $self->{DBH}->do(sprintf("DELETE from RepositoryContentData where localpath = %s", $self->{DBH}->quote($file) ) );
    }

    printLog($self->{LOG}, "info", sprintf(__("Finished cleaning: '%s'"), $self->fullLocalRepoPath() )) if(!$isYum);
    printLog($self->{LOG}, "info", sprintf(__("=> Removed files : %s"), $cnt)) if(!$isYum);
    printLog($self->{LOG}, "info", sprintf(__("=> Clean Time    : %s"), SMT::Utils::timeFormat(tv_interval($t0)))) if(!$isYum);
    print "\n" if(!$isYum);
}

=item verify([%params])

 $mirror->verify();

 Returns 1 (true), if the repo is valid, otherwise 0 (false).

=over 4

=item removeinvalid

If set to 1, invalid files are removed from the local harddisk.

=item quiet

If set to 1, no reports are printed.

=back

=cut

sub verify()
{
    my $self = shift;
    my %options = @_;

    my $t0 = [gettimeofday] ;

    # if path was not defined, we can use last
    # mirror destination dir
    if ( ! -d $self->fullLocalRepoPath() )
    {
        printLog($self->{LOG}, "error", sprintf(__("Destination '%s' does not exist"), $self->fullLocalRepoPath() ));
        $self->{STATISTIC}->{ERROR} += 1;
        return ($self->{STATISTIC}->{ERROR} == 0);
    }

    # remove invalid packages?
    my $removeinvalid = 0;
    $removeinvalid = 1 if ( exists $options{removeinvalid} && $options{removeinvalid} );

    my $quiet = 0;
    $quiet = 1 if( exists $options{quiet} && defined $options{quiet} && $options{quiet} );

    printLog($self->{LOG}, "info", sprintf(__("Verifying: %s"), $self->fullLocalRepoPath() )) if(!$quiet);

    $self->{STATISTIC}->{ERROR} = 0;
    
    # parse it and find more resources
    my $parser = SMT::Parser::RpmMd->new(log => $self->{LOG});
    $parser->resource( $self->fullLocalRepoPath() );
    $parser->parse("repodata/repomd.xml", sub { verify_handler($self, @_)});

    my $job;
    my $cnt = 0;
    foreach (sort keys %{$self->{VERIFYJOBS}} )
    {
        $job = $self->{VERIFYJOBS}->{$_};
        
        my $ok = ( (-e $job->fullLocalPath()) && $job->verify());
        $cnt++;
        if ($ok || ($job->localFileLocation() =~ /repomd\.xml$/ ) )
        {
            printLog($self->{LOG}, "debug", "Verify: ". $job->fullLocalPath() . ": OK") if ($self->debug());
        }
        else
        {
            if(!-e $job->fullLocalPath())
            {
                printLog($self->{LOG}, "error", "Verify: ". $job->fullLocalPath() . ": FAILED ( file not found )");
            }
            else
            {
                printLog($self->{LOG}, "error", "Verify: ". $job->fullLocalPath() . ": ".sprintf("FAILED ( %s vs %s )", $job->checksum(), $job->realchecksum()));
                if ($removeinvalid)
                {
                    printLog($self->{LOG}, "debug", sprintf(__("Deleting %s"), $job->fullLocalPath())) if ($self->debug());
                    unlink($job->fullLocalPath());
                }
            }
            $self->{DBH}->do(sprintf("DELETE from RepositoryContentData where localpath = %s", $self->{DBH}->quote($job->fullLocalPath() ) ) );
            
            $self->{STATISTIC}->{ERROR} += 1;
        }
    }

    if( !$quiet )
    {
        printLog($self->{LOG}, "info", sprintf(__("=> Finished verifying: %s"), $self->fullLocalRepoPath() ));
        printLog($self->{LOG}, "info", sprintf(__("=> Files             : %s"), $cnt ));
        printLog($self->{LOG}, "info", sprintf(__("=> Errors            : %s"), $self->{STATISTIC}->{ERROR} ));
        printLog($self->{LOG}, "info", sprintf(__("=> Verify Time       : %s"), SMT::Utils::timeFormat(tv_interval($t0)) ));
        print "\n";
    }
    
    return ($self->{STATISTIC}->{ERROR} == 0);
}


sub clean_handler
{
    my $self = shift;
    my $data = shift;

    if(exists $data->{LOCATION} && defined $data->{LOCATION} &&
       $data->{LOCATION} ne "" )
    {
        # get the repository index
        my $resource = SMT::Utils::cleanPath($self->fullLocalRepoPath(), $data->{LOCATION});
        
        # if this path is in the CLEANLIST, delete it
        delete $self->{CLEANLIST}->{$resource} if (exists $self->{CLEANLIST}->{$resource});
    }
    if(exists $data->{PKGFILES} && ref($data->{PKGFILES}) eq "ARRAY")
    {
        foreach my $file (@{$data->{PKGFILES}})
        {
            if(exists $file->{LOCATION} && defined $file->{LOCATION} &&
               $file->{LOCATION} ne "" )
            {
                # get the repository index
                my $resource = SMT::Utils::cleanPath( $self->fullLocalRepoPath(), $file->{LOCATION} );
                
                # if this path is in the CLEANLIST, delete it
                delete $self->{CLEANLIST}->{$resource} if (exists $self->{CLEANLIST}->{$resource});
            }
        }
    }
}


sub download_handler
{
    my $self   = shift;
    my $dryrun = shift;
    my $data   = shift;

    
    if(exists $data->{LOCATION} && defined $data->{LOCATION} &&
       $data->{LOCATION} ne "" && !exists $self->{JOBS}->{$data->{LOCATION}})
    {
        if(!$self->{MIRRORSRC} && exists $data->{ARCH} && defined $data->{ARCH} && lc($data->{ARCH}) eq "src")
        {
            # we do not want source rpms - skip
            printLog($self->{LOG}, "debug", "Skip source RPM: ".$data->{LOCATION}) if($self->debug());
            
            return;
        }

        # get the repository index
        my $job = SMT::Mirror::Job->new(debug => $self->debug(), useragent => $self->{USERAGENT}, 
                                        log => $self->{LOG}, dbh => $self->{DBH}, nohardlink => $self->{NOHARDLINK} );
        $job->uri( $self->{URI} );
        $job->localBasePath( $self->localBasePath() );
        $job->localRepoPath( $self->localRepoPath() );
        $job->localFileLocation( $data->{LOCATION} );
        $job->checksum( $data->{CHECKSUM} );
        
        my $fullpath = "";

        if($data->{LOCATION} =~ /^repodata/)
        {
            $fullpath = SMT::Utils::cleanPath( $self->fullLocalRepoPath(), ".".$data->{LOCATION} );
        }
        else
        {
            $fullpath = $job->fullLocalPath();
        }
        
        if( exists $self->{EXISTS}->{$fullpath} && 
            $self->{EXISTS}->{$fullpath}->{checksum} eq $data->{CHECKSUM} && 
            -e "$fullpath" )
        {
            # file exists and is up-to-date. 
            # with deepverify call a verify 
            if( $self->deepverify() && !$job->verify() )
            {
                #printLog($self->{LOG}, "debug", "deepverify: verify failed") if($self->debug());
                unlink ( $job->fullLocalPath() ) if( !$dryrun );
            }
            else
            {
                printLog($self->{LOG}, "debug", sprintf("U %s", $job->fullLocalPath() )) if($self->debug());
                $self->{STATISTIC}->{UPTODATE} += 1;
                return;
            }
        }
        elsif( -e "$fullpath" )
        {
            # file exists but is not in the database. Check if it is valid.
            if( $job->verify() )
            {
                # File is ok, so update the database and go to the next file
                $job->updateDB();
                printLog($self->{LOG}, "debug", sprintf("U %s", $job->fullLocalPath() )) if($self->debug());
                $self->{STATISTIC}->{UPTODATE} += 1;
                return;
            }
            else
            {
                # hmmm, invalid. Remove it if we are not in dryrun mode
                unlink ( $job->fullLocalPath() ) if( !$dryrun );
            }
        }
        
        # if it is an xml file we have to download it now and
        # process it
        if (  $job->localFileLocation() =~ /(.+)\.xml(.*)/ )
        {
            # metadata! change the download area

            my $localres = $data->{LOCATION};
            
            $localres =~ s/repodata/.repodata/;
            $job->remoteFileLocation( $data->{LOCATION} );
            $job->localFileLocation( $localres );

            # mirror it first, so we can parse it
            my $mres = $job->mirror();
            $self->{DOWNLOAD_SIZE} += int($job->downloadSize());
            if( $mres == 1 )
            {
                $self->{STATISTIC}->{ERROR} += 1;
            }
            elsif( $mres == 2 ) # up-to-date
            {
                if($self->deepverify() && !$job->verify())
                {
                    # remove broken file and download it again
                    unlink($job->fullLocalPath());
                    $mres = $job->mirror();
                    if($mres = 0)
                    {
                        $self->{STATISTIC}->{DOWNLOAD} += 1;
                    }
                    else
                    {
                        # error
                        $self->{STATISTIC}->{ERROR} += 1;
                    }
                }
                else
                {
                    $self->{STATISTIC}->{UPTODATE} += 1;
                }
            }
            else
            {
                $self->{STATISTIC}->{DOWNLOAD} += 1;
            }
        }
        else
        {
            # download it later
            if ( $job->localFileLocation() )
            {
                if(!exists $self->{JOBS}->{$data->{LOCATION}})
                {
                    $self->{JOBS}->{$data->{LOCATION}} = $job;
                }
            }
            else
            {
                printLog($self->{LOG}, "error", "no file location set on ".$job->fullLocalPath());
            }
        }
    }
    if(exists $data->{PKGFILES} && ref($data->{PKGFILES}) eq "ARRAY")
    {
        foreach my $file (@{$data->{PKGFILES}})
        {
            if(exists $file->{LOCATION} && defined $file->{LOCATION} &&
               $file->{LOCATION} ne "" && !exists $self->{JOBS}->{$file->{LOCATION}})
            {
                my $job = SMT::Mirror::Job->new(debug => $self->debug(), useragent => $self->{USERAGENT}, log => $self->{LOG},
                                                dbh => $self->{DBH}, nohardlink => $self->{NOHARDLINK} );
                $job->uri( $self->{URI} );
                $job->localBasePath( $self->localBasePath() );
                $job->localRepoPath( $self->localRepoPath() );
                $job->localFileLocation( $file->{LOCATION} );
                $job->checksum( $file->{CHECKSUM} );
                
                #my $fullpath = SMT::Utils::cleanPath( $self->fullLocalRepoPath(), $file->{LOCATION} );
        
                if( exists $self->{EXISTS}->{$job->fullLocalPath()} && 
                    $self->{EXISTS}->{$job->fullLocalPath()}->{checksum} eq $file->{CHECKSUM} && 
                    -e $job->fullLocalPath() )
                {
                    # file exists and is up-to-date. 
                    # with deepverify call a verify 
                    if( $self->deepverify() && $job->verify() )
                    {
                        $self->{STATISTIC}->{UPTODATE} += 1;
                        next;
                    }
                    else
                    {
                        unlink ( $job->fullLocalPath() ) if( !$dryrun );
                    }
                }
                
                $self->{JOBS}->{$file->{LOCATION}} = $job;
            }
        }
    }
}

sub verify_handler
{
    my $self = shift;
    my $data = shift;

    if(!$self->{MIRRORSRC} && exists $data->{ARCH} && defined $data->{ARCH} && lc($data->{ARCH}) eq "src")
    {
        # we do not want source rpms - skip
        printLog($self->{LOG}, "debug", "Skip source RPM: ".$data->{LOCATION}) if($self->debug());
        
        return;
    }
    
    if(exists $data->{LOCATION} && defined $data->{LOCATION} &&
       $data->{LOCATION} ne "")
    {
        # if LOCATION has the string "repodata" we want to verify them
        # this matches also for "/.repodata/"
        # all other files (rpms) are verified only if deepverify is requested.
        if($self->deepverify() || $data->{LOCATION} =~ /repodata/)
        {
            my $job = SMT::Mirror::Job->new(debug => $self->debug(), useragent => $self->{USERAGENT}, log => $self->{LOG}, 
                                            dbh => $self->{DBH}, nohardlink => $self->{NOHARDLINK});
            $job->localBasePath( $self->localBasePath() );
            $job->localRepoPath( $self->localRepoPath() );
            $job->localFileLocation( $data->{LOCATION} );
            $job->checksum( $data->{CHECKSUM} );
            
            if(!exists $self->{VERIFYJOBS}->{$job->fullLocalPath()})
            {
                $self->{VERIFYJOBS}->{$job->fullLocalPath()} = $job;
            }
        }
    }
    if($self->deepverify() && exists $data->{PKGFILES} && ref($data->{PKGFILES}) eq "ARRAY")
    {
        foreach my $file (@{$data->{PKGFILES}})
        {
            if(exists $file->{LOCATION} && defined $file->{LOCATION} &&
               $file->{LOCATION} ne "" && !exists $self->{JOBS}->{$file->{LOCATION}})
            {
                my $job = SMT::Mirror::Job->new(debug => $self->debug(), useragent => $self->{USERAGENT}, log => $self->{LOG}, 
                                                dbh => $self->{DBH}, nohardlink => $self->{NOHARDLINK} );
                $job->localBasePath( $self->localBasePath() );
                $job->localRepoPath( $self->localRepoPath() );
                $job->localFileLocation( $file->{LOCATION} );
                $job->checksum( $file->{CHECKSUM} );
                
                if(!exists $self->{VERIFYJOBS}->{$job->fullLocalPath()})
                {
                    $self->{VERIFYJOBS}->{$job->fullLocalPath()} = $job;
                }
            }
        }
    }
}

=back

=head1 AUTHOR

dmacvicar@suse.de, mc@suse.de

=head1 COPYRIGHT

Copyright 2007, 2008, 2009 SUSE LINUX Products GmbH, Nuernberg, Germany.

=cut


1;  # so the require or use succeeds
