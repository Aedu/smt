package SMT::Parser::ListReg;
use strict;
use URI;
use XML::Parser;
use SMT::Utils;
use IO::Zlib;


# The handler is called with something like this
#
# $VAR1 = {
#           'SLES10' => {
#                       'SERVERCLASS' => 'ADDON',
#                       'DURATION' => '60',
#                       'STATUS' => 'ACTIVE',
#                       'TYPE' => 'FULL',
#                       'ENDDATE' => '1202149302',
#                       'STARTDATE' => '1202149301'
#                     },
#           'GUID' => 'adbeef4abadb013564'
#         };


# constructor
sub new
{
    my $pkgname = shift;
    my %opt   = @_;
    my $self  = {};

    $self->{CURRENT}   = undef;
    $self->{HANDLER}   = undef;
    $self->{ELEMENT}   = undef;
    $self->{CURSUB}    = undef;
    $self->{LOG}       = undef;

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

# parses a xml resource
sub parse()
{
    my $self     = shift;
    my $file     = shift;
    my $handler  = shift;
    
    $self->{HANDLER} = $handler;
    
    if (!defined $file)
    {
        printLog($self->{LOG}, "error", "Invalid filename");
        exit 1;
    }

    if (!-e $file)
    {
        printLog($self->{LOG}, "error", "File '$file' does not exist.");
        exit 1;
    }
    
    my $parser = XML::Parser->new( Handlers =>
                                   {
                                    Start=> sub { handle_start_tag($self, @_) },
                                    Char => sub { handle_char_tag($self, @_) },
                                    End=> sub { handle_end_tag($self, @_) },
                                   });

    if ( $file =~ /(.+)\.gz/ )
    {
        my $fh = IO::Zlib->new($file, "rb");
        eval {
            $parser->parse( $fh );
        };
        if ($@) {
            # ignore the errors, but print them
            chomp($@);
            printLog($self->{LOG}, "error", "SMT::Parser::ListReg Invalid XML in '$file': $@");
        }
    }
    else
    {
        eval {
            $parser->parsefile( $file );
        };
        if ($@) {
            # ignore the errors, but print them
            chomp($@);
            printLog($self->{LOG}, "error", "SMT::Parser::ListReg Invalid XML in '$file': $@");
        }
    }
}

# handles XML reader start tag events
sub handle_start_tag()
{
    my $self = shift;
    my( $expat, $element, %attrs ) = @_;

    if(lc($element) eq "guid")
    {
        $self->{ELEMENT} = "GUID";
        $self->{CURRENT}->{GUID} = "";
    }
    elsif(lc($element) eq "subscription" && exists $attrs{name} && defined $attrs{name})
    {
        $self->{CURSUB} = $attrs{name};
        $self->{CURRENT}->{$self->{CURSUB}}->{TYPE} = "";
        $self->{CURRENT}->{$self->{CURSUB}}->{STATUS} = "";
        $self->{CURRENT}->{$self->{CURSUB}}->{STARTDATE} = "";
        $self->{CURRENT}->{$self->{CURSUB}}->{ENDDATE} = "";
        $self->{CURRENT}->{$self->{CURSUB}}->{DURATION} = "";
        $self->{CURRENT}->{$self->{CURSUB}}->{SERVERCLASS} = "";
    }
    elsif(defined $self->{CURSUB} && lc($element) eq "type")
    {
        $self->{ELEMENT} = "type";
    }
    elsif(defined $self->{CURSUB} && lc($element) eq "substatus")
    {
        $self->{ELEMENT} = "substatus";
    }
    elsif(defined $self->{CURSUB} && lc($element) eq "start-date")
    {
        $self->{ELEMENT} = "start-date";
    }
    elsif(defined $self->{CURSUB} && lc($element) eq "end-date")
    {
        $self->{ELEMENT} = "end-date";
    }
    elsif(defined $self->{CURSUB} && lc($element) eq "duration")
    {
        $self->{ELEMENT} = "duration";
    }
    elsif(defined $self->{CURSUB} && lc($element) eq "server-class")
    {
        $self->{ELEMENT} = "server-class";
    }
}

sub handle_char_tag
{
    my $self = shift;
    my( $expat, $string) = @_;

    chomp($string);
    return if($string =~ /^\s*$/);

    if(defined $self->{ELEMENT} && $self->{ELEMENT} eq "GUID")
    {
        $self->{CURRENT}->{GUID} .= $string;
    }
    elsif(defined $self->{CURSUB} && $self->{CURSUB} ne "")
    {
        if(defined $self->{ELEMENT} && $self->{ELEMENT} eq "type")
        {
            $self->{CURRENT}->{$self->{CURSUB}}->{TYPE} .= $string;
        }
        elsif(defined $self->{ELEMENT} && $self->{ELEMENT} eq "substatus")
        {
            $self->{CURRENT}->{$self->{CURSUB}}->{STATUS} .= $string;
        }
        elsif(defined $self->{ELEMENT} && $self->{ELEMENT} eq "start-date")
        {
            $self->{CURRENT}->{$self->{CURSUB}}->{STARTDATE} .= $string;
        }
        elsif(defined $self->{ELEMENT} && $self->{ELEMENT} eq "end-date")
        {
            $self->{CURRENT}->{$self->{CURSUB}}->{ENDDATE} .= $string;
        }
        elsif(defined $self->{ELEMENT} && $self->{ELEMENT} eq "duration")
        {
            $self->{CURRENT}->{$self->{CURSUB}}->{DURATION} .= $string;
        }
        elsif(defined $self->{ELEMENT} && $self->{ELEMENT} eq "server-class")
        {
            $self->{CURRENT}->{$self->{CURSUB}}->{SERVERCLASS} .= $string;
        }
    }
}

sub handle_end_tag
{
    my( $self, $expat, $element ) = @_;

    if(lc($element) eq "client")
    {
        # first call the callback
        $self->{HANDLER}->($self->{CURRENT});

        $self->{ELEMENT} = undef; 
        $self->{CURSUB}  = undef;
        $self->{CURRENT} = undef;
    }
    elsif(lc($element) eq "subscription")
    {
        $self->{CURSUB}  = undef;
    }
    
}

1;


