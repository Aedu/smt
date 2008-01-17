package YEP::Parser::NU;
use strict;
use URI;
use XML::Parser;

=head1 NAME

YEP::Parser::NU - parsers NU repoindex.xml file

=head1 SYNOPSIS

  sub handler()
  {
    my $data = shift;
    print $data->{NAME};
    print $data->{DISTRO_TARGET};
    print $data->{PATH};
    print $data->{DESCRIPTION};
    print $data->{PRIORITY};
  }

  $parser = YEP::Parser::NU->new();
  $parser->parse("repoindex.xml", \&handler);

=head1 DESCRIPTION

Parses a repoindex.xml file and calls the handler function
passing every repoindex.xml repo entry to it.

=head1 METHODS

=over 4

=item new()

Create a new YEP::Parser::NU object:

=over 4

=item parse

Starts parsing

=back

=head1 AUTHOR

dmacvicar@suse.de

=head1 COPYRIGHT

Copyright 2007, 2008 SUSE LINUX Products GmbH, Nuernberg, Germany.

=cut

# constructor
sub new
{
    my $self  = {};

    $self->{CURRENT}   = undef;
    $self->{HANDLER}   = undef;

    bless($self);
    return $self;
}

# parses a xml resource
sub parse()
{
    my $self     = shift;
    my $path     = shift;
    my $handler  = shift;
    
    $self->{HANDLER} = $handler;
    
    my $parser;
    
    $parser = XML::Parser->new( Handlers =>
                                { Start=> sub { handle_start_tag($self, @_) },
                                  End=> sub { handle_end_tag($self, @_) },
                                });
    
    if ( $path =~ /(.+)\.gz/ )
    {
      use IO::Zlib;
      my $fh = IO::Zlib->new($path, "rb");
      eval {
          # using ->parse( $fh ) result in errors
          my @cont = $fh->getlines();
          $parser->parse( join("", @cont ));
      };
      if($@) {
          # ignore the errors, but print them
          chomp($@);
          print STDERR "Error: $@\n";
      }
    }
    else
    {
      eval {
          $parser->parsefile( $path );
      };
      if($@) {
          # ignore the errors, but print them
          chomp($@);
          print STDERR "Error: $@\n";
      }
    }
}

# handles XML reader start tag events
sub handle_start_tag()
{
    my $self = shift;
    my( $expat, $element, %attrs ) = @_;
    # ask the expat object about our position
    my $line = $expat->current_line;

    # we are looking for <repo .../>
    if ( $element eq "repo" )
    {
        my $data = {};
        $data->{NAME} = $attrs{"name"};
        $data->{DISTRO_TARGET} = $attrs{"distro_target"};
        $data->{PATH} = $attrs{"path"};
        $data->{DESCRIPTION} = $attrs{"description"};
        $data->{PRIORITY} = int($attrs{"priority"});
        $self->{CURRENT} = $data;
    }
}


sub handle_end_tag()
{
  my $self = shift;
  my( $expat, $element, %attrs ) = @_;
  if ( $element eq "repo" )
  {
    # call the callback
    $self->{HANDLER}->($self->{CURRENT});
    $self->{CURRENT} = undef;
  }
}

1;
