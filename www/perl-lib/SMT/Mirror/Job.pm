package SMT::Mirror::Job;
use strict;

use LWP::UserAgent;
use File::Path;
use File::Basename;
use Date::Parse;
use Crypt::SSLeay;
use Digest::SHA1  qw(sha1 sha1_hex);
use SMT::Utils;

BEGIN 
{
    if(exists $ENV{https_proxy})
    {
        # required for Crypt::SSLeay HTTPS Proxy support
        $ENV{HTTPS_PROXY} = $ENV{https_proxy};
    }
}

sub new
{
    my $pkgname = shift;
    my %opt   = @_;
    
    my $self  = {};
    $self->{URI}        = undef;
    $self->{LOCALDIR}   = undef;
    $self->{RESOURCE}   = undef;
    $self->{RESOURCEEXT}   = undef;   # if we need to set a different resource remote and local
    $self->{CHECKSUM}   = undef;
    # Do _NOT_ set env_proxy for LWP::UserAgent, this would break https proxy support
    $self->{USERAGENT}  = (defined $opt{UserAgent} && $opt{UserAgent})?$opt{UserAgent}:LWP::UserAgent->new(keep_alive => 1);
    $self->{DEBUG}      = 0;
    $self->{LOG}        = undef;
    $self->{JOBTYPE}    = undef;

    if(exists $ENV{http_proxy})
    {
        $self->{USERAGENT}->proxy("http",  $ENV{http_proxy});
    }
    
    if(exists $opt{debug} && defined $opt{debug} && $opt{debug})
    {
        $self->{DEBUG} = 1;
    }

    if(exists $opt{log} && defined $opt{log} && $opt{log})
    {
        $self->{LOG} = $opt{log};
    }
    else
    {
        $self->{LOG} = SMT::Utils::openLog();
    }

    bless($self);
    return $self;
}

# URI property
sub uri
{
    my $self = shift;
    if (@_) { $self->{URI} = shift }
    
    return $self->{URI};
}

# job type
sub type
{
    my $self = shift;
    if (@_) { $self->{JOBTYPE} = shift }
    
    return $self->{JOBTYPE};
}

# local resource container
sub localdir
{
    my $self = shift;
    if (@_) { $self->{LOCALDIR} = shift }
    return $self->{LOCALDIR};
}

sub remoteresource
{
    my $self = shift;
    
    if(@_) { $self->{RESOURCEEXT} = shift }
    return $self->{RESOURCEEXT};
}
    

# local full path
sub local
{
    my $self = shift;
    my $local = join( "/", ( $self->{LOCALDIR}, $self->{RESOURCE} ) );
    return $local;
}

# local full path
sub remote
{
    my $self = shift;
    if(defined $self->{RESOURCEEXT} && $self->{RESOURCEEXT} ne "")
    {
        return $self->{URI}."/".$self->{RESOURCEEXT};
    }
    else
    {
        return $self->{URI}."/".$self->{RESOURCE};
    }
}

# resource property
sub resource
{
    my $self = shift;
    if (@_) { $self->{RESOURCE} = shift }
    return $self->{RESOURCE};
}

# checksum property
sub checksum()
{
    my $self = shift;
    if (@_) { $self->{CHECKSUM} = shift }
    return $self->{CHECKSUM};
}

# verify the local copy of the job with the known
# checksum without accesing the network
sub verify()
{
    my $self = shift;
     
    return 0 if ( not $self->checksum() eq  $self->realchecksum() );
    return 1;
}

sub realchecksum()
{
    my $self = shift;
    
    my $sha1;
    my $digest;
    my $filename = $self->local;
    open(FILE, "< $filename") or do {
        printLog($self->{LOG}, "debug", "Cannot open '$filename': $!") if($self->{DEBUG});
        return "";
    };
    
    $sha1 = Digest::SHA1->new;
    $sha1->addfile(*FILE);
    $digest = $sha1->hexdigest();
    return $digest;
}

# mirror the resource to the local destination
sub mirror
{
    my $self = shift;

    if ( not $self->outdated() )
    {
        printLog($self->{LOG}, "debug", sprintf("----> %s is up to date", $self->{RESOURCE})) if($self->{DEBUG});
        # no need to mirror
        return 2;
    }
    else
    {
        if($self->{DEBUG})
        {
            printLog($self->{LOG}, "debug", sprintf("Fetch [%s]", $self->resource()));
        }
    }
    
    # make sure the container destination exists
    &File::Path::mkpath( dirname($self->local()) );

    my $response = $self->{USERAGENT}->get( $self->remote(), ':content_file' => $self->local() );
    
    if ( $response->is_redirect )
    {
        printLog($self->{LOG}, "debug", "Redirected") if($self->{DEBUG});
        return 1;
    }

    if( $response->is_success )
    {
        return 0;
    }
    else
    {
        my $saveuri = URI->new($self->remote());
        $saveuri->userinfo(undef);
        
        printLog($self->{LOG}, "error", sprintf(__("Failed to download '%s': %s"), 
                                                $saveuri->as_string(), $response->status_line));
        return 1;
    }
}

# remote modification timestamp
sub modified
{
    my $self = shift;
    
    my $response = $self->{USERAGENT}->head( $self->remote() );
    
    $response->is_success or do 
    {
        my $saveuri = URI->new($self->remote());
        $saveuri->userinfo(undef);
        printLog($self->{LOG}, "error", sprintf(__("Failed to download '%s': %s"), 
                                                $saveuri->as_string() , $response->status_line));
        return undef;
    };

    return Date::Parse::str2time($response->header( "Last-Modified" ));
}

# true if remote is newer than local version
# or if local does not exists
sub outdated
{
    my $self = shift;
    
    if ( not -e $self->local() )
    {
        return 1;
    }
    
    my $date = (stat $self->local())[9];
    my $modifiedAt = $self->modified();
    
    return (!defined $modifiedAt || $date < $modifiedAt);
}

sub print
{
    my $self = shift;
    print "[", $self->resource(), "]\n";
}

=head1 NAME

SMT::Mirror::Job - represents a single resource mirror job

=head1 SYNOPSIS

  $job = SMT::Mirror::Job->new();
  $job->uri("http://foo.com/");
  $job->localdir("/tmp");
  $job->resource("/file.txt");
  # when was it last time modified remotely
  print $job->modified()
  # is the local version outdated?
  print $job->outdated()
  $job->mirror();

=head1 DESCRIPTION

Represents a remote resource mirror job and provice
useful mehods to check if the resource exists local
or if it needs refresh and to transfer it.

=head1 METHODS

=over 4

=item new([$params])

Create a new SMT::Mirror::Job object:

  my $mirror = SMT::Mirror::Job->new(debug => 1);

Arguments are an anonymous hash array of parameters:

=over 4

=item debug

Set to 1 to enable debug. 

=item UserAgent

LWP::UserAgent object to use for this job. Usefull for keep_alive. 

=back

=item mirror()

Returns 0 on success, 1 on error and 2 if the file is up to date

=back

=head1 AUTHOR

dmacvicar@suse.de

=head1 COPYRIGHT

Copyright 2007, 2008 SUSE LINUX Products GmbH, Nuernberg, Germany.

=cut

1;  # so the require or use succeeds
