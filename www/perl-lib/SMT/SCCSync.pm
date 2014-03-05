package SMT::SCCSync;
use strict;

use URI;
use SMT::SCCAPI;
use SMT::Utils;
use File::Temp;
use DBI qw(:sql_types);

use Data::Dumper;


# constructor
sub new
{
    my $pkgname = shift;
    my %opt   = @_;

    my $self  = {};

    $self->{URI}   = undef;
    $self->{VBLEVEL} = 0;
    $self->{LOG}   = undef;
    $self->{USERAGENT}  = undef;

    $self->{MAX_REDIRECTS} = 5;

    $self->{AUTHUSER} = "";
    $self->{AUTHPASS} = "";

    $self->{MIGRATE} = 0;

    $self->{HTTPSTATUS} = 0;

    if (! defined $opt{fromdir} ) {
        $self->{SMTGUID} = SMT::Utils::getSMTGuid();
    }

    $self->{NCCEMAIL} = "";

    $self->{DBH} = undef;

    $self->{TEMPDIR} = File::Temp::tempdir("smt-XXXXXXXX", CLEANUP => 1, TMPDIR => 1);

    $self->{FROMDIR} = undef;
    $self->{TODIR}   = undef;

    $self->{ERRORS} = 0;

    $self->{REPO_DONE} = {};

    if(exists $opt{vblevel} && $opt{vblevel})
    {
        $self->{VBLEVEL} = $opt{vblevel};
    }

    if(exists $opt{log} && $opt{log})
    {
        $self->{LOG} = $opt{log};
    }
    else
    {
        $self->{LOG} = SMT::Utils::openLog();
    }

    if(exists $opt{fromdir} && defined $opt{fromdir} && -d $opt{fromdir})
    {
        $self->{FROMDIR} = $opt{fromdir};
    }
    elsif(exists $opt{todir} && defined $opt{todir} && -d $opt{todir})
    {
        $self->{TODIR} = $opt{todir};
    }

    if(exists $opt{dbh} && defined $opt{dbh} && $opt{dbh})
    {
        $self->{DBH} = $opt{dbh};
    }
    elsif(!defined $self->{TODIR} || $self->{TODIR} eq "")
    {
        # init the database only if we do not sync to a directory
        $self->{DBH} = SMT::Utils::db_connect();
    }

    if(exists $opt{nccemail} && defined $opt{nccemail})
    {
        $self->{NCCEMAIL} = $opt{nccemail};
    }

    if(exists $opt{useragent} && defined $opt{useragent} && $opt{useragent})
    {
        $self->{USERAGENT} = $opt{useragent};
    }
    else
    {
        $self->{USERAGENT} = SMT::Utils::createUserAgent(log => $self->{LOG}, vblevel => $self->{VBLEVEL});
        $self->{USERAGENT}->protocols_allowed( [ 'https'] );
    }

    my ($ruri, $user, $pass) = SMT::Utils::getLocalRegInfos();

    $self->{URI}      = $ruri;
    $self->{AUTHUSER} = $user;
    $self->{AUTHPASS} = $pass;

    $self->{API} = SMT::SCCAPI->new(vblevel => $self->{VBLEVEL},
                                    log     => $self->{LOG},
                                    useragent => $self->{USERAGENT},
                                    url => $self->{URI},
                                    authuser => $self->{AUTHUSER},
                                    autpass => $self->{AUTHPASS},
                                    ident => $self->{SMTGUID}
                                   );
    bless($self);

    return $self;
}

=item vblevel([level])

Set or get the verbose level.

=cut

sub vblevel
{
    my $self = shift;
    if (@_) { $self->{VBLEVEL} = shift }
    return $self->{VBLEVEL};
}

sub migrate
{
    my $self = shift;
    if (@_) { $self->{MIGRATE} = shift }
    return $self->{MIGRATE};
}

sub products
{
    my $self = shift;
    my $input = undef;

    if($self->{FROMDIR} && -d $self->{FROMDIR})
    {
        open( FH, '<', $self->{FROMDIR}."/products.json" ) and do
        {
            my $json_text   = <FH>;
            $input = JSON::decode_json( $json_text );
            close FH;
        };

    }
    else
    {
        $input = $self->{API}->products();
    }
    if (! $input)
    {
        return 1;
    }
    if(defined $self->{TODIR})
    {
        open( FH, '>', $self->{TODIR}."/products.json") or do
        {
            printLog($self->{LOG}, $self->{VBLEVEL}, LOG_ERROR, "Cannot open file: $!");
            return 1;
        };
        my $json_text = JSON::encode_json($input);
        print FH "$json_text";
        close FH;
        return 0;
    }
    else
    {
        my $ret = $self->_updateData($input);
        return $ret;
    }
}

###############################################################################
###############################################################################
###############################################################################
###############################################################################

sub _updateProducts
{
    my $self = shift;
    my $product = shift;

    my $statement = "";
    my $paramlist =<<EOP
<paramlist xmlns="http://www.novell.com/xml/center/regsvc-1_0"
lang="">
  <guid description="" class="mandatory" />
  <param id="secret" description="" command="zmd-secret"
  class="mandatory" />
  <host description="" />
  <product description="" class="mandatory" />
  <param id="ostarget" description="" command="zmd-ostarget"
  class="mandatory" />
  <param id="ostarget-bak" description="" command="lsb_release -sd"
  class="mandatory" />
  <param id="processor" description="" command="uname -p" />
  <param id="platform" description="" command="uname -i" />
  <param id="hostname" description="" command="uname -n" />
  <param id="cpu" description="" command="hwinfo --cpu" />
  <param id="memory" description="" command="hwinfo --memory" />
</paramlist>
EOP
;
    my $needinfo =<<EON
<?xml version="1.0" encoding="utf-8"?>
<needinfo xmlns="http://www.novell.com/xml/center/regsvc-1_0"
lang="" href="">
  <guid description="" class="mandatory" />
  <param id="secret" description="" command="zmd-secret"
  class="mandatory" />
  <host description="" />
  <product description="" class="mandatory" />
  <param id="ostarget" description="" command="zmd-ostarget"
  class="mandatory" />
  <param id="ostarget-bak" description="" command="lsb_release -sd"
  class="mandatory" />
  <param id="sysident" description="">
    <param id="processor" description="" command="uname -p" />
    <param id="platform" description="" command="uname -i" />
    <param id="hostname" description="" command="uname -n" class="mandatory"/>
  </param>
  <param id="hw_inventory" description="">
    <param id="cpu" description="" command="hwinfo --cpu" />
    <param id="memory" description="" command="hwinfo --memory" />
  </param>
  <privacy url="http://www.novell.com/company/policies/privacy/textonly.html"
  description="" class="informative" />
</needinfo>
EON
;
    my $service =<<EOS
<service xmlns="http://www.novell.com/xml/center/regsvc-1_0"
id="\${mirror:id}" description="\${mirror:name}" type="\${mirror:type}">
  <param id="url">\${mirror:url}</param>
  <group-catalogs/>
</service>
EOS
;

    if (! $self->migrate() && (my $pid = SMT::Utils::lookupProductIdByDataId($self->{DBH}, $product->{id}, 'S')))
    {
        $statement = sprintf("UPDATE Products
                                 SET PRODUCT = %s, VERSION = %s,
                                     REL = %s, ARCH = %s,
                                     PRODUCTLOWER = %s, VERSIONLOWER = %s,
                                     RELLOWER = %s, ARCHLOWER = %s,
                                     FRIENDLY = %s, PRODUCT_LIST = %s,
                                     PRODUCT_CLASS = %s, PRODUCTDATAID = %s
                               WHERE ID = %s",
                             $self->{DBH}->quote($product->{zypper_name}),
                             $self->{DBH}->quote($product->{zypper_version}),
                             $self->{DBH}->quote($product->{release}),
                             $self->{DBH}->quote($product->{arch}),
                             $self->{DBH}->quote(lc($product->{zypper_name})),
                             $self->{DBH}->quote(lc($product->{zypper_version})),
                             $self->{DBH}->quote(lc($product->{release})),
                             $self->{DBH}->quote(lc($product->{arch})),
                             $self->{DBH}->quote($product->{friendly}),
                             $self->{DBH}->quote(($product->{product_list}?'Y':'N')),
                             $self->{DBH}->quote($product->{product_class}),
                             $self->{DBH}->quote($product->{id}),
                             $self->{DBH}->quote($pid)
        );
    }
    elsif ($self->migrate() && ($pid = SMT::Utils::lookupProductIdByName($self->{DBH}, $product->{zypper_name},
                                                                            $product->{zypper_version},
                                                                            $product->{release},
                                                                            $product->{arch})))
    {
        $statement = sprintf("UPDATE Products
                                 SET PRODUCT = %s, VERSION = %s,
                                     REL = %s, ARCH = %s,
                                     PRODUCTLOWER = %s, VERSIONLOWER = %s,
                                     RELLOWER = %s, ARCHLOWER = %s,
                                     FRIENDLY = %s, PRODUCT_LIST = %s,
                                     PRODUCT_CLASS = %s, PRODUCTDATAID = %s,
                                     SRC = 'S'
                               WHERE ID = %s",
                             $self->{DBH}->quote($product->{zypper_name}),
                             $self->{DBH}->quote($product->{zypper_version}),
                             $self->{DBH}->quote($product->{release}),
                             $self->{DBH}->quote($product->{arch}),
                             $self->{DBH}->quote(lc($product->{zypper_name})),
                             $self->{DBH}->quote(lc($product->{zypper_version})),
                             $self->{DBH}->quote(lc($product->{release})),
                             $self->{DBH}->quote(lc($product->{arch})),
                             $self->{DBH}->quote($product->{friendly}),
                             $self->{DBH}->quote(($product->{product_list}?'Y':'N')),
                             $self->{DBH}->quote($product->{product_class}),
                             $self->{DBH}->quote($product->{id}),
                             $self->{DBH}->quote($pid)
        );
    }
    else
    {
        $statement = sprintf("INSERT INTO Products (PRODUCT, VERSION, REL, ARCH,
                              PRODUCTLOWER, VERSIONLOWER, RELLOWER, ARCHLOWER,
                              PARAMLIST, NEEDINFO, SERVICE,
                              FRIENDLY, PRODUCT_LIST, PRODUCT_CLASS, PRODUCTDATAID, SRC)
                              VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'S')",
                             $self->{DBH}->quote($product->{zypper_name}),
                             $self->{DBH}->quote($product->{zypper_version}),
                             $self->{DBH}->quote($product->{release}),
                             $self->{DBH}->quote($product->{arch}),
                             $self->{DBH}->quote(lc($product->{zypper_name})),
                             $self->{DBH}->quote(lc($product->{zypper_version})),
                             $self->{DBH}->quote(lc($product->{release})),
                             $self->{DBH}->quote(lc($product->{arch})),
                             $self->{DBH}->quote($paramlist),
                             $self->{DBH}->quote($needinfo),
                             $self->{DBH}->quote($service),
                             $self->{DBH}->quote($product->{friendly}),
                             $self->{DBH}->quote(($product->{product_list}?'Y':'N')),
                             $self->{DBH}->quote($product->{product_class}),
                             $self->{DBH}->quote($product->{id}));
    }
    printLog($self->{LOG}, $self->vblevel(), LOG_DEBUG, "STATEMENT: $statement");
    eval {
        $self->{DBH}->do($statement);
    };
    if($@)
    {
        printLog($self->{LOG}, $self->vblevel(), LOG_ERROR, "$@");
        return 1;
    }
    return 0;
}

sub _updateRepositories
{
    my $self = shift;
    my $repo = shift;
    my $statement = "";

    # we inserted/update this repo already in this run
    # so let's skip it
    return 0 if(exists $self->{REPO_DONE}->{$repo->{id}});

    my $localpath = "RPMMD/".$repo->{name};
    if (grep( ($_ == 'nu' || $_ == 'ris' || $_ == 'yum'), @{$repo->{flags}}))
    {
        $localpath = $repo->{name}."/".$repo->{distro_target};
    }
    # FIXME: add sles10sp1 ATI and nVidia special
    my $exthost = URI->new($repo->{url});
    $exthost->path(undef);
    $exthost->fragment(undef);
    $exthost->query(undef);

    my $catalogtype = 'nu';
    if (grep( ($_ == 'zypp' || $_ == 'repomd'), @{$repo->{flags}}))
    {
        $catalogtype = 'zypp';
    }
    elsif (grep( ($_ == 'yum'), @{$repo->{flags}}))
    {
        $catalogtype = 'yum';
    }

    if (! $self->migrate() && (my $cid = SMT::Utils::lookupCatalogIdByDataId($self->{DBH}, $repo->{id}, 'S')))
    {
        $statement = sprintf("UPDATE Catalogs
                                 SET NAME = %s, DESCRIPTION = %s,
                                     TARGET = %s, LOCALPATH = %s,
                                     EXTHOST = %s, EXTURL = %s,
                                     CATALOGTYPE = %s, CATALOGID = %s
                               WHERE ID = %s",
                             $self->{DBH}->quote($repo->{name}),
                             $self->{DBH}->quote($repo->{description}),
                             $self->{DBH}->quote($repo->{distro_target}),
                             $self->{DBH}->quote($localpath),
                             $self->{DBH}->quote($exthost),
                             $self->{DBH}->quote($repo->{url}),
                             $self->{DBH}->quote($catalogtype),
                             $self->{DBH}->quote($repo->{id}),
                             $self->{DBH}->quote($cid)
        );
    }
    elsif ($self->migrate() && ($cid = SMT::Utils::lookupCatalogIdByName($self->{DBH}, $repo->{name}, $repo->{distro_target})))
    {
        $statement = sprintf("UPDATE Catalogs
                                 SET NAME = %s, DESCRIPTION = %s,
                                     TARGET = %s, LOCALPATH = %s,
                                     EXTHOST = %s, EXTURL = %s,
                                     CATALOGTYPE = %s, CATALOGID = %s,
                                     SRC = 'S'
                               WHERE ID = %s",
                             $self->{DBH}->quote($repo->{name}),
                             $self->{DBH}->quote($repo->{description}),
                             $self->{DBH}->quote($repo->{distro_target}),
                             $self->{DBH}->quote($localpath),
                             $self->{DBH}->quote($exthost),
                             $self->{DBH}->quote($repo->{url}),
                             $self->{DBH}->quote($catalogtype),
                             $self->{DBH}->quote($repo->{id}),
                             $self->{DBH}->quote($cid)
        );
    }
    else
    {
        $statement = sprintf("INSERT INTO Catalogs (NAME, DESCRIPTION, TARGET, LOCALPATH,
                              EXTHOST, EXTURL, CATALOGTYPE, CATALOGID, SRC)
                              VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'S')",
                             $self->{DBH}->quote($repo->{name}),
                             $self->{DBH}->quote($repo->{description}),
                             $self->{DBH}->quote($repo->{distro_target}),
                             $self->{DBH}->quote($localpath),
                             $self->{DBH}->quote($exthost),
                             $self->{DBH}->quote($repo->{url}),
                             $self->{DBH}->quote($catalogtype),
                             $self->{DBH}->quote($repo->{id})
        );
    }
    printLog($self->{LOG}, $self->vblevel(), LOG_DEBUG, "STATEMENT: $statement");
    eval {
        $self->{DBH}->do($statement);
        $self->{REPO_DONE}->{$repo->{id}} = 1;
    };
    if($@)
    {
        printLog($self->{LOG}, $self->vblevel(), LOG_ERROR, "$@");
        return 1;
    }
    return 0;
}

sub _updateProductCatalogs
{
    my $self = shift;
    my $product = shift;
    my $repo = shift;
    my $ret = 0;
    my $product_id = SMT::Utils::lookupProductIdByDataId($self->{DBH}, $product->{id}, 'S');
    my $repo_id = SMT::Utils::lookupCatalogIdByDataId($self->{DBH}, $repo->{id}, 'S');
    if (! $product_id)
    {
        printLog($self->{LOG}, $self->vblevel(), LOG_ERROR, "Unable to find Product ID for: ".$product->{id});
        printLog($self->{LOG}, $self->vblevel(), LOG_DEBUG, "Unable to find Product ID for: ".Data::Dumper->Dump([$product]));
        return 1;
    }
    if (! $repo_id)
    {
        printLog($self->{LOG}, $self->vblevel(), LOG_ERROR, "Unable to find Repository ID: ".$repo->{id});
        return 1;
    }
    my $statement = sprintf("DELETE FROM ProductCatalogs
                              WHERE PRODUCTID = %s AND CATALOGID = %s",
                            $self->{DBH}->quote($product_id),
                            $self->{DBH}->quote($repo_id)
    );
    printLog($self->{LOG}, $self->vblevel(), LOG_DEBUG, "STATEMENT: $statement");
    eval {
        $self->{DBH}->do($statement);
    };
    if($@)
    {
        printLog($self->{LOG}, $self->vblevel(), LOG_ERROR, "$@");
        $ret += 1;
    }
    my $optional = ((grep $_ == 'optional', @{$repo->{flags}})?"Y":"N");

    $statement = sprintf("INSERT INTO ProductCatalogs (PRODUCTID, CATALOGID, OPTIONAL, SRC)
                          VALUES (%s, %s, %s, 'S')",
                         $self->{DBH}->quote($product_id),
                         $self->{DBH}->quote($repo_id),
                         $self->{DBH}->quote($optional));
    printLog($self->{LOG}, $self->vblevel(), LOG_DEBUG, "STATEMENT: $statement");
    eval {
        $self->{DBH}->do($statement);
    };
    if($@)
    {
        printLog($self->{LOG}, $self->vblevel(), LOG_ERROR, "$@");
        $ret += 1;
    }
    return $ret;
}

sub _updateData
{
    my $self = shift;
    my $json = shift;
    my $ret = 0;

    if(!defined $self->{DBH})
    {
        printLog($self->{LOG}, $self->vblevel(), LOG_ERROR, "Cannot connect to database.");
        return 1;
    }

    foreach my $product (@$json)
    {
        $ret += $self->_updateProducts($product);

        foreach my $repo (@{$product->{repos}})
        {
            $ret += $self->_updateRepositories($repo);
            $ret += $self->_updateProductCatalogs($product, $repo);
        }
    }
    return $ret;
}

1;
