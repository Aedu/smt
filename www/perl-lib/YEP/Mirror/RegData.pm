package YEP::Mirror::RegData;
use strict;

use LWP::UserAgent;
use URI;
use XML::Parser;
use XML::Writer;
use Crypt::SSLeay;
use YEP::Utils;
use File::Temp;

use Data::Dumper;

BEGIN
{
    if(exists $ENV{https_proxy})
    {
        # required for Crypt::SSLeay HTTPS Proxy support
        $ENV{HTTPS_PROXY} = $ENV{https_proxy};
    }
}

# constructor
sub new
{
    my $pkgname = shift;
    my %opt   = @_;

    my $self  = {};

    $self->{URI}   = undef;
    $self->{DEBUG} = 0;
    # Do _NOT_ set env_proxy for LWP::UserAgent, this would break https proxy support
    $self->{USERAGENT}  = LWP::UserAgent->new(keep_alive => 1);
    push @{ $self->{USERAGENT}->requests_redirectable }, 'POST';
    # FIXME: remove http for production
    $self->{USERAGENT}->protocols_allowed( [ 'http', 'https'] );
    $self->{USERINFO} = "";

    $self->{TEMPDIR} = File::Temp::tempdir(CLEANUP => 1);

    $self->{ELEMENT} = "";
    $self->{TABLE}   = "";
    $self->{KEY}     = [];
    
    $self->{XML}->{ROWNUM}  = 0;
    $self->{XML}->{ROOT}    = undef;
    $self->{XML}->{CURELEM} = undef;
    $self->{XML}->{ATTR}    = undef;
    $self->{XML}->{DATA}    = {};
    
    if(exists $ENV{http_proxy})
    {
        $self->{USERAGENT}->proxy("http",  $ENV{http_proxy});
    }

    if(exists $opt{debug} && defined $opt{debug} && $opt{debug})
    {
        $self->{DEBUG} = 1;
    }

    if(exists $opt{element} && defined $opt{element} && $opt{element} ne "")
    {
        $self->{ELEMENT} = $opt{element};
    }

    if(exists $opt{table} && defined $opt{table} && $opt{table} ne "")
    {
        $self->{TABLE} = $opt{table};
    }

  
    # get the URI from /etc/suseRegister.conf

    open(FH, "< /etc/suseRegister.conf") and do
    {
        while(<FH>)
        {
            if($_ =~ /^url\s*=\s*(\S*)\s*/ && defined $1 && $1 ne "")
            {
                $self->{URI} = $1;
                last;
            }
        }
        close FH;
    };

    # get the USERINFO - /etc/zmd/deviceid, /etc/zmd/secret

    open(FH, "< /etc/zmd/deviceid") and do
    {
        $self->{USERINFO} = <FH>;
        chomp($self->{USERINFO});
        close FH;
    };
    open(FH, "< /etc/zmd/secret") and do
    {
        my $s = <FH>;
        chomp($s);
        $self->{USERINFO} .= ":$s";
        close FH;
    };

    if(!defined $self->{URI} || $self->{URI} eq "")
    {
        die "URL not found.";
    }
    if(!defined $self->{USERINFO} || $self->{USERINFO} !~ /^.+:.+$/)
    {
        die "Invalid user informations .".$self->{USERINFO};
    }    
    
    bless($self);

    if(exists $opt{key} && defined $opt{key})
    {
        $self->key($opt{key});
    }
    
    return $self;
}

# element property
sub element
{
    my $self = shift;
    if (@_) { $self->{ELEMENT} = shift }

    return $self->{ELEMENT};
}

# table property
sub table
{
    my $self = shift;
    if (@_) { $self->{TABLE} = shift }

    return $self->{TABLE};
}

# keyproperty
sub key
{
    my $self = shift;
    if (@_) 
    { 
        my $data = shift;
        if(ref($data) eq "ARRAY")
        {
            $self->{KEY} = $data;
        }
        elsif(ref($data) eq "")
        {
            $self->{KEY} = [$data];
        }
    }
    return $self->{KEY};
}


sub sync
{
    my $self = shift;
    

    my $xmlfile = $self->_requestData();
    if(!$xmlfile)
    {
        return 1;
    }
    
    $self->_parseXML($xmlfile);
    return $self->_updateDB();
}


sub _requestData
{
    my $self    = shift;

    my $uri = URI->new($self->{URI});
    $uri->userinfo($self->{USERINFO});
    $uri->query("command=regdata");
    
    my $content = "";
    my $writer = new XML::Writer(NEWLINES => 1, OUTPUT => \$content);
    $writer->xmlDecl();
    $writer->emptyTag($self->{ELEMENT}, xmlns => "http://www.novell.com/center/xml/regsvc10");
    
    my $response = $self->{USERAGENT}->post( $uri->as_string(), 
                                             ':content_file' => $self->{TEMPDIR}."/".$self->{ELEMENT}.".xml",
                                             'Content' => $content);
    
    if ( $response->is_redirect )
    {
        print "Redirected", "\n" if($self->{DEBUG});
        return undef;
    }
    
    if( $response->is_success )
    {
        return $self->{TEMPDIR}."/".$self->{ELEMENT}.".xml";
    }
    else
    {
        # FIXME: was 'die'; check if we should stop if a download failed
        print STDERR "Failed to POST '$uri->as_string()': ".$response->status_line."\n";
        return undef;
    }
}

sub _parseXML
{
    my $self    = shift;
    my $xmlfile = shift;

    if(! -e $xmlfile)
    {
        die "File '$xmlfile' does not exist.";
    }

    my $parser = XML::Parser->new( Handlers =>
                                   { Start => sub { handle_start_tag($self, @_) },
                                     End   => sub { handle_end_tag($self, @_) },
                                     Char  => sub { handle_char($self, @_) }
                                   });
 
    eval {
        $parser->parsefile( $xmlfile );
    };
    if($@) {
        # ignore the errors, but print them
        chomp($@);
        print STDERR "Error: $@\n";
    }
    return 0;
}

sub _updateDB
{
    my $self  = shift;

    my $table = $self->{TABLE};
    my $key   = $self->{KEY};
    
    if(!defined $table || $table eq "")
    {
        die "Invalid table name";
    }
    if(!defined $key || ref($key) ne "ARRAY")
    {
        die "Invalid key element.";
    }
    
    if(! exists $self->{XML}->{DATA}->{$self->{ELEMENT}})
    {
        # data not available; no need to update the database
        print STDERR "WARNING: No content for $self->{ELEMENT}\n";
        return 1;
    }
    
    my $dbh = YEP::Utils::db_connect();
    if(!defined $dbh)
    {
        die "Cannot connect to database.";
    }
    
    foreach my $row (@{$self->{XML}->{DATA}->{$self->{ELEMENT}}})
    {
        my @primkeys_where = ();
        foreach (@$key) 
        {
            push @primkeys_where, "$_=".$dbh->quote($row->{$_});
        }

        # does the key exists in the db?
        my $st = sprintf("SELECT %s FROM %s WHERE %s", 
                         join(',', @$key), $table, join(' AND ', @primkeys_where));
        
        print "STATEMENT: $st\n" if($self->{DEBUG});
                    
        my $all = $dbh->selectall_arrayref($st);

        print Data::Dumper->Dump([$all])  if($self->{DEBUG});

        # special handling for catalogs table
        # LOCALPATH is required
        if(lc($table) eq "catalogs")
        {
            if(lc($row->{CATALOGTYPE}) eq "nu")
            {
                $row->{LOCALPATH} = '$RCE/'.$row->{NAME}."/".$row->{TARGET};
            }
            else
            {
                $row->{LOCALPATH} = 'YUM/'.$row->{NAME};
            }
        }

        

        # PRIMARY KEY exists in DB, do update
        if(@$all == 1)
        {
            my $statement = "UPDATE $table SET ";
            my @pairs = ();
            foreach my $cn (keys %$row)
            {
                next if( grep( ($_ eq $cn), @$key ) );

                push @pairs, "$cn = ".$dbh->quote($row->{$cn});
            }
            
            # if all columns of a table are part of the primary key 
            # no update is needed. We found this with the select above.
            # This row is up-to-date.
            next if(@pairs == 0);
            
            $statement .= join(', ', @pairs);

            $statement .= " WHERE ".join(' AND ', @primkeys_where);
            
            print "STATEMENT: $statement\n" if($self->{DEBUG});

            $dbh->do($statement);
            
        }
        # PRIMARY KEY does not exists in DB, do insert
        elsif(@$all == 0)
        {
            my $statement = "INSERT INTO $table (";
            my @k = ();
            my @v = ();
            foreach my $cn (keys %$row)
            {
                push @k, $cn;
                push @v, $dbh->quote($row->{$cn});
            }

            $statement .= join(',', @k);
            $statement .= ") VALUES (";
            $statement .= join(',', @v);
            $statement .= ")";
            
            print "STATEMENT: $statement\n" if($self->{DEBUG});
            
            $dbh->do($statement);
        }
        else
        {
            # more then one element by selecting the keyvalue - evil
            print STDERR "ERROR: invalid key value '$key'\n";
        }
    }
    $dbh->disconnect;
    return 0;
}


sub handle_start_tag
{
    my $self = shift;
    my( $expat, $element, %attrs ) = @_;

    #print "Element '$element' Start: ".Data::Dumper->Dump([\%attrs])."\n";

    $self->{XML}->{CURELEM} = lc($element);

    if(lc($self->{XML}->{CURELEM}) eq "col" && exists $attrs{name} &&
       defined $attrs{name} && $attrs{name} ne "")
    {
        $self->{XML}->{ATTR} = $attrs{name};
        $self->{XML}->{DATA}->{$self->{XML}->{ROOT}}->[$self->{XML}->{ROWNUM}]->{$self->{XML}->{ATTR}} = undef;
    }
    elsif(lc($element) eq "row")
    {
        push @{$self->{XML}->{DATA}->{$self->{XML}->{ROOT}}}, {};
        $self->{XML}->{ROWNUM} = $#{$self->{XML}->{DATA}->{$self->{XML}->{ROOT}}};
    }
    elsif(!defined $self->{XML}->{ROOT})
    {
        $self->{XML}->{ROOT} = $self->{XML}->{CURELEM};
        $self->{XML}->{DATA}->{$self->{XML}->{ROOT}} = [];
        #print "ROOT: ".$self->{XML}->{ROOT}."\n";
    }

}

sub handle_end_tag
{
  my( $self, $expat, $element ) = @_;

  #print "End $element\n";
  $self->{XML}->{ATTR} = undef;

  if(lc($element) eq lc($self->{XML}->{ROOT}))
  {
      $self->{XML}->{ROOT}= undef;
  }
}

sub handle_char
{
    my $self = shift;
    my( $expat, $string) = @_;

    chomp($string);

    return if($string =~ /^\s*$/);    

    if(lc($self->{XML}->{CURELEM}) eq "col" && defined $self->{XML}->{ATTR} && $self->{XML}->{ATTR} ne "")
    {
        if(uc($self->{XML}->{ATTR}) eq "EXTURL")
        {
            $string =~ s/^\s*//g;
            $string =~ s/\s*$//g;
        }
        
        if( !defined $self->{XML}->{DATA}->{$self->{XML}->{ROOT}}->[$self->{XML}->{ROWNUM}]->{$self->{XML}->{ATTR}} )
        {
            $self->{XML}->{DATA}->{$self->{XML}->{ROOT}}->[$self->{XML}->{ROWNUM}]->{$self->{XML}->{ATTR}} = $string;
        }
        else
        {
            $self->{XML}->{DATA}->{$self->{XML}->{ROOT}}->[$self->{XML}->{ROWNUM}]->{$self->{XML}->{ATTR}} .= "\n$string";
        }
    }
}

1;




