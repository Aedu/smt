package SMT::CLI;
use strict;
use warnings;

use URI;
use SMT::Utils;
use Text::ASCIITable;
use Config::IniFiles;
use File::Temp;
use IO::File;
use SMT::Parser::NU;
use SMT::Mirror::Job;
use XML::Writer;

use File::Basename;
use Digest::SHA1  qw(sha1 sha1_hex);
use Time::HiRes qw(gettimeofday tv_interval);

use Locale::gettext ();
use POSIX ();     # Needed for setlocale()

POSIX::setlocale(&POSIX::LC_MESSAGES, "");

#use vars qw($cfg $dbh $nuri);

#print "hello CLI2\n";


sub init
{
    my $dbh;
    my $cfg;
    my $nuri;
    if ( not $dbh=SMT::Utils::db_connect() )
    {
        die __("ERROR: Could not connect to the database");
    }

    #print "hello CLI\n";
    $cfg = new Config::IniFiles( -file => "/etc/smt.conf" );
    if(!defined $cfg)
    {
        die __("Cannot read the SMT configuration file: ").@Config::IniFiles::errors;
    }

    # TODO move the url assembling code out
    my $NUUrl = $cfg->val("NU", "NUUrl");
    if(!defined $NUUrl || $NUUrl eq "")
    {
      die __("Cannot read NU Url");
    }

    my $nuUser = $cfg->val("NU", "NUUser");
    my $nuPass = $cfg->val("NU", "NUPass");
    
    if(!defined $nuUser || $nuUser eq "" ||
      !defined $nuPass || $nuPass eq "")
    {
        die __("Cannot read the Mirror Credentials");
    }

    $nuri = URI->new($NUUrl);
    $nuri->userinfo("$nuUser:$nuPass");

    return ($cfg, $dbh, $nuri);
}

sub listCatalogs
{
    my %options = @_;

    my ($cfg, $dbh, $nuri) = init();
    my $sql = "select * from Catalogs";

    $sql = $sql . " where 1";

    if ( exists $options{ mirrorable } && defined $options{mirrorable} )
    {
          if (  $options{ mirrorable } == 1 )
          {
            $sql = $sql . " and MIRRORABLE='Y'";
          }
          else
          {
            $sql = $sql . " and MIRRORABLE='N'";
          }
    }

    if ( exists $options{ name } && defined $options{name} )
    {
          $sql = $sql . sprintf(" and NAME=%s", $dbh->quote($options{name}));
    }
    
    if ( exists $options{ domirror } && defined  $options{ domirror } )
    {
          if (  $options{ domirror } == 1 )
          {
            $sql = $sql . " and DOMIRROR='Y'";
          }
          else
          {
            $sql = $sql . " and DOMIRROR='N'";
          }
    }

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $t = new Text::ASCIITable;

    my @cols;
    #push( @cols, "ID" );
    push( @cols, "Name" );
    push( @cols, "Description" );

    push( @cols, "Mirrorable" );
    push( @cols, "Mirror?" );

    
    $t->setCols(@cols);

    my $counter = 1;
    while (my $values = $sth->fetchrow_hashref())  
    {
        my @row;
        #push( @row, $values->{CATALOGID} );
        #push( @row, $counter );
        push( @row, $values->{NAME} );
        push( @row, $values->{DESCRIPTION} );
        push( @row, $values->{MIRRORABLE} );
        push( @row, $values->{DOMIRROR} );
        #print $values->{CATALOGID} . " => [" . $values->{NAME} . "] " . $values->{DESCRIPTION} . "\n";
        
        $t->addRow(@row);

        if ( exists $options{ used } && defined $options{used} )
        {
          $t->addRow("", $values->{EXTURL}, "", "");
          $t->addRow("", $values->{LOCALPATH}, "", "");
          $t->addRow("", $values->{CATALOGTYPE}, "", "");
        }
        
        $counter++;
    }
    print $t->draw();
    $sth->finish();
}

sub listProducts
{
    my %options = @_;
    my ($cfg, $dbh, $nuri) = init();

    my $sql = "select p.*,0+(select count(r.GUID) from Products p2, Registration r where r.PRODUCTID=p2.PRODUCTDATAID and p2.PRODUCTDATAID=p.PRODUCTDATAID) AS registered_machines from Products p where 1";

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $t = new Text::ASCIITable;
    $t->setCols(__('Name'),__('Version'), __('Target'), __('Usage'));
    
    while (my $value = $sth->fetchrow_hashref())  # keep fetching until 
                                                   # there's nothing left
    {
        #print "$nickname, $favorite_number\n";
        #print "$PRODUCT $VERSION $ARCH\n";
        my $productstr = $value->{PRODUCT};
        $productstr .= " $value->{VERSION}" if(defined $value->{VERSION});
        $productstr .= " $value->{ARCH}" if(defined $value->{ARCH});
        #print "$productstr\n";
        
        next if ( exists($options{ used }) && defined($options{used}) && (int($value->{registered_machines}) < 1) );
        
        $t->addRow($value->{PRODUCT}, defined($value->{VERSION}) ? $value->{VERSION} : "-", defined($value->{ARCH}) ? $value->{ARCH} : "-", $value->{registered_machines});
    }
    print $t->draw();
    $sth->finish();
}

sub listRegistrations
{
    my ($cfg, $dbh, $nuri) = init();

    my $clients = $dbh->selectall_arrayref("SELECT GUID, HOSTNAME, LASTCONTACT from Clients ORDER BY LASTCONTACT", {Slice => {}});

    my $t = new Text::ASCIITable;
    $t->setOptions('drawRowLine',1);
    $t->setCols(__('Unique ID'),__('Hostname'), __('Last Contact'), __('Product'));

    foreach my $clnt (@{$clients})
    {
        my $products = $dbh->selectall_arrayref(sprintf("SELECT p.PRODUCT, p.VERSION, p.REL, p.ARCH from Products p, Registration r WHERE r.GUID=%s and r.PRODUCTID=p.PRODUCTDATAID", 
                                                        $dbh->quote($clnt->{GUID})), {Slice => {}});
        
        my $prdstr = "";
        foreach my $product (@{$products})
        {
            $prdstr .= $product->{PRODUCT} if(defined $product->{PRODUCT});
            $prdstr .= " ".$product->{VERSION} if(defined $product->{VERSION});
            $prdstr .= " ".$product->{REL} if(defined $product->{REL});
            $prdstr .= " ".$product->{ARCH} if(defined $product->{ARCH});
            $prdstr .= "\n";
        }
        $t->addRow($clnt->{GUID}, $clnt->{HOSTNAME}, $clnt->{LASTCONTACT}, $prdstr);
    }
    print $t->draw();
}

sub resetCatalogsStatus
{
  my ($cfg, $dbh, $nuri) = init();

  my $sth = $dbh->prepare(qq{UPDATE Catalogs SET Mirrorable='N' WHERE CATALOGTYPE='nu'});
  $sth->execute();
}

sub setCatalogDoMirror
{
  my %opt = @_;
  my ($cfg, $dbh, $nuri) = init();

  if(exists $opt{enabled} && defined $opt{enabled} )
  {
    my $sql = "update Catalogs";
    $sql .= sprintf(" set Domirror=%s", $dbh->quote(  $opt{enabled} ? "Y" : "N" ) ); 

    $sql .= " where 1";

    $sql .= sprintf(" and Mirrorable=%s", $dbh->quote("Y"));

    if(exists $opt{name} && defined $opt{name} )
    {
      $sql .= sprintf(" and NAME=%s", $dbh->quote($opt{name}));
    }

    if(exists $opt{target} && defined $opt{target} )
    {
      $sql .= sprintf(" and TARGET=%s", $dbh->quote($opt{target}));
    }

    if(exists $opt{id} && defined $opt{id} )
    {
      $sql .= sprintf(" and CATALOGID=%s", $dbh->quote($opt{id}));
    }

    #print $sql . "\n";
    my $sth = $dbh->prepare($sql);
    $sth->execute();

  }
  else
  {
    die __("enabled option missing");
  }
}

sub catalogDoMirrorFlag
{
  my %options = @_;
  my ($cfg, $dbh, $nuri) = init();
  return 1;
}

sub setMirrorableCatalogs
{
    my %opt = @_;
    my ($cfg, $dbh, $nuri) = init();

    # create a tmpdir to store repoindex.xml
    my $destdir = File::Temp::tempdir(CLEANUP => 1);
    my $indexfile = "";
    if(exists $opt{todir} && defined $opt{todir} && -d $opt{todir})
    {
        $destdir = $opt{todir};
    }

    if(exists $opt{fromdir} && defined $opt{fromdir} && -d $opt{fromdir})
    {
        $indexfile = $opt{fromdir}."/repo/repoindex.xml";
    }
    else
    {
        # get the file
        my $job = SMT::Mirror::Job->new();
        $job->uri($nuri);
        $job->localdir($destdir);
        $job->resource("/repo/repoindex.xml");
    
        $job->mirror();
        $indexfile = $job->local();
    }

    if(exists $opt{todir} && defined $opt{todir} && -d $opt{todir})
    {
        # with todir we only want to mirror repoindex to todir
        return;
    }

    my $parser = SMT::Parser::NU->new();
    $parser->parse($indexfile, sub {
                                    my $repodata = shift;
                                    print __(sprintf("* set [" . $repodata->{NAME} . "] [" . $repodata->{DISTRO_TARGET} . "] as mirrorable.\n"));
                                    my $sth = $dbh->do( sprintf("UPDATE Catalogs SET Mirrorable='Y' WHERE NAME=%s AND TARGET=%s", $dbh->quote($repodata->{NAME}), $dbh->quote($repodata->{DISTRO_TARGET}) ));
                               }
    );

    my $sql = "select CATALOGID, NAME, LOCALPATH, EXTURL, TARGET from Catalogs where CATALOGTYPE='zypp'";
    #my $sth = $dbh->prepare($sql);
    #$sth->execute();
    #while (my @values = $sth->fetchrow_array())
    my $values = $dbh->selectall_arrayref($sql);
    foreach my $v (@{$values})
    { 
        my $catName = $v->[1];
        my $catLocal = $v->[2];
        my $catUrl = $v->[3];
        my $catTarget = $v->[4];
        if( $catUrl ne "" && $catLocal ne "" )
        {
	    my $ret = 1;
            if(exists $opt{fromdir} && defined $opt{fromdir} && -d $opt{fromdir})
            {
		    # fromdir is used on a server without internet connection
		    # we define that the catalogs are mirrorable
		    $ret = 0;
	    }
	    else
	    {
    	        my $tempdir = File::Temp::tempdir(CLEANUP => 1);
                my $job = SMT::Mirror::Job->new();
                $job->uri($catUrl);
                $job->localdir($tempdir);
                $job->resource("/repodata/repomd.xml");
          
                # if no error
                $ret = $job->mirror();
	    }
            print __(sprintf ("* set [" . $catName . "] as " . ( ($ret == 0) ? '' : ' not ' ) . " mirrorable.\n"));
            my $sth = $dbh->do( sprintf("UPDATE Catalogs SET Mirrorable=%s WHERE NAME=%s AND TARGET=%s", ( ($ret == 0) ? $dbh->quote('Y') : $dbh->quote('N') ), $dbh->quote($catName), $dbh->quote($catTarget) ) );
        }
    }

    my $mirrorAll = $cfg->val("LOCAL", "MirrorAll");
    if(defined $mirrorAll && lc($mirrorAll) eq "true")
    {
        # set DOMIRROR to Y where MIRRORABLE = Y
        $dbh->do("UPDATE Catalogs SET DOMIRROR='Y' WHERE MIRRORABLE='Y'");
    }
}

sub removeCustomCatalog
{
    my %options = @_;
    my ($cfg, $dbh, $nuri) = init();

    # delete existing catalogs with this id

    my $affected1 = $dbh->do(sprintf("DELETE from Catalogs where CATALOGID=%s", $dbh->quote($options{catalogid})));
    my $affected2 = $dbh->do(sprintf("DELETE from ProductCatalogs where CATALOGID=%s", $dbh->quote($options{catalogid})));

    return ($affected1 || $affected2);
}

sub setupCustomCatalogs
{
    my %options = @_;
    my ($cfg, $dbh, $nuri) = init();

    # delete existing catalogs with this id
    
    removeCustomCatalog(%options);
    
    # now insert it again.
    my $exthost = $options{exturl};
    $exthost =~ /^(https?:\/\/[^\/]+\/)/;
    $exthost = $1;

    my $affected = $dbh->do(sprintf("INSERT INTO Catalogs (CATALOGID, NAME, DESCRIPTION, TARGET, LOCALPATH, EXTHOST, EXTURL, CATALOGTYPE, DOMIRROR,MIRRORABLE ) VALUES(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                                    $dbh->quote($options{catalogid}),
                                    $dbh->quote($options{name}),
                                    $dbh->quote($options{description}),
                                    "NULL",
                                    $dbh->quote("/RPMMD/".$options{name}),
                                    $dbh->quote($exthost),
                                    $dbh->quote($options{exturl}),
                                    $dbh->quote("zypp"),
                                    $dbh->quote("Y"),
                                    $dbh->quote("Y")));
    foreach my $pid (@{$options{productids}})
    {
        $affected += $dbh->do(sprintf("INSERT INTO ProductCatalogs VALUES(%s, %s, %s)",
                                      $pid,
                                      $dbh->quote($options{catalogid}),
                                      $dbh->quote("N")));
    }
    
    return (($affected>0)?1:0);
}

sub createDBReplacementFile
{
    my $xmlfile = shift;
    my ($cfg, $dbh, $nuri) = init();

    my $dbout = $dbh->selectall_hashref("SELECT CATALOGID, NAME, DESCRIPTION, TARGET, EXTURL, LOCALPATH, CATALOGTYPE from Catalogs where DOMIRROR = 'Y'", 
                                        "CATALOGID");

    my $output = new IO::File(">$xmlfile");
    my $writer = new XML::Writer(OUTPUT => $output);

    $writer->xmlDecl("UTF-8");
    $writer->startTag("catalogs", xmlns => "http://www.novell.com/xml/center/regsvc-1_0");

    foreach my $row (keys %{$dbout})
    {
        $writer->startTag("row");
        foreach my $col (keys %{$dbout->{$row}})
        {
            $writer->startTag("col", name => $col);
            $writer->characters($dbout->{$row}->{$col});
            $writer->endTag("col");
        }
        $writer->endTag("row");
    }
    $writer->endTag("catalogs");
    $writer->end();
    $output->close();

    return ;
}

sub hardlink
{
    my %options = @_;
    my ($cfg, $dbh, $nuri) = init();
    my $t0 = [gettimeofday] ;

    my $debug = 0;
    $debug = $options{debug} if(exists $options{debug} && defined $options{debug});

    my $dir = $cfg->val("LOCAL", "MirrorTo");
    if(!defined $dir || $dir eq "" || ! -d $dir)
    {
        printLog($options{log}, "error", sprintf("Wrong mirror directory: %s", $dir));
        return 1;
    }
    my $cmd = "find $dir -xdev -iname '*.rpm' -type f -size +$options{size}k ";
    printLog($options{log}, "info", "$cmd") if($debug);
    
    my $filelist = `$cmd`;
    my @files = sort split(/\n/, $filelist);
    my @f2 = @files;
    
    foreach my $MM (@files)
    {
        foreach my $NN (@f2)
        {
            next if (!defined $NN);

            if( $NN ne $MM  &&  basename($MM) eq basename($NN) )
            {
                printLog($options{log}, "info", "$MM ");
                printLog($options{log}, "info", "$NN ");
                if( (stat($MM))[1] != (stat($NN))[1] )
                {
                    my $sha1MM = _sha1sum($MM);
                    my $sha1NN = _sha1sum($NN);
                    if(defined $sha1MM && defined $sha1NN && $sha1MM eq $sha1NN)
                    {
                        printLog($options{log}, "info", "Do hardlink");
                        #my $ret = link $MM, $NN;
                        #print "RET: $ret\n";
                        `ln -f '$MM' '$NN'`;
                        $NN = undef;
                    }
                    else
                    {
                        printLog($options{log}, "info", "Checksums does not match $sha1MM != $sha1NN.");
                    }
                }
                else
                {
                    printLog($options{log}, "info", "Files are hard linked. Nothing to do.");
                    $NN = undef;
                }
            }
            elsif($NN eq $MM)
            {
                $NN = undef;
            }
        }
    }
    printLog($options{log}, "info", sprintf(__("Hardlink Time      : %s seconds"), (tv_interval($t0))));
}

sub productClassReport
{
    my %options = @_;
    my ($cfg, $dbh, $nuri) = init();
    my %conf;
    
    my $debug = 0;
    $debug = $options{debug} if(exists $options{debug} && defined $options{debug});
    
    if(exists $options{conf} && defined $options{conf} && ref($options{conf}) eq "HASH")
    {
        %conf = %{$options{conf}};
    }
    else
    {
        printLog($options{log}, "error", "Invalid configuration provided.");
        return undef;
    }
    
    my $t = new Text::ASCIITable;
    $t->setCols(__("Product Class"), __("Architecture"), __("Installed Clients"));
    
    
    my $classes = $dbh->selectcol_arrayref("SELECT DISTINCT PRODUCT_CLASS from Products where PRODUCT_CLASS is not NULL");
    
    foreach my $class (@{$classes})
    {
        my $found = 0;
        
        my $cn = $class;
        $cn = $conf{$class}->{NAME} if(exists $conf{$class}->{NAME} && defined $conf{$class}->{NAME});
        
        my %groups = %{$conf{SMT_DEFAULT}->{ARCHGROUPS}};
        %groups = %{$conf{$class}->{ARCHGROUPS}} if(exists $conf{$class}->{ARCHGROUPS} && defined $conf{$class}->{ARCHGROUPS});
        
        foreach my $archgroup (keys %groups)
        {
            my $statement = "SELECT COUNT(DISTINCT GUID) from Registration where PRODUCTID IN (";
            $statement .= sprintf("SELECT PRODUCTDATAID from Products where PRODUCT_CLASS=%s AND ", 
                                  $dbh->quote($class));
            
            if(@{$groups{$archgroup}} == 1)
            {
                if(defined @{$groups{$archgroup}}[0])
                {
                    $statement .= sprintf(" ARCHLOWER = %s", $dbh->quote(@{$groups{$archgroup}}[0]));
                }
                else
                {
                    $statement .= " ARCHLOWER IS NULL";
                }
            }
            elsif(@{$groups{$archgroup}} > 1)
            {
                $statement .= sprintf(" ARCHLOWER IN('%s')", join("','", @{$groups{$archgroup}}));
            }
            else
            {
                die "This should not happen";
            }
            
            $statement .= ")";
            
            printLog($options{log}, "debug", "STATEMENT: $statement") if($debug);
            
            my $count = $dbh->selectcol_arrayref($statement);
            
            if(exists $count->[0] && defined $count->[0] && $count->[0] > 0)
            {
                $t->addRow("$cn", $archgroup, $count->[0]);
                $found = 1;
            }
        }
        
        if(!$found)
        {
            # this select is for products which do not have an architecture set (ARCHLOWER is NULL) 
            my $statement = "SELECT COUNT(DISTINCT GUID) from Registration where PRODUCTID IN (";
            $statement .= sprintf("SELECT PRODUCTDATAID from Products where PRODUCT_CLASS=%s)", 
                                  $dbh->quote($class));
            
            printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);
            
            my $count = $dbh->selectcol_arrayref($statement);
            
            if(exists $count->[0] && defined $count->[0] && $count->[0] > 0)
            {
                $t->addRow("$cn", "", $count->[0]);
                $found = 1;
            }
        }
    }
    return $t->draw();
}

sub productSubscriptionReport
{
    my %options = @_;
    my ($cfg, $dbh, $nuri) = init();
    my $report = "";
    
    my $debug = 0;
    $debug = $options{debug} if(exists $options{debug} && defined $options{debug});

    my $statement = "";
    my $time = SMT::Utils::getDBTimestamp();
    my $calchash = {};
    my $expireSoonMachines = {};
    my $expiredMachines = {};
    

    $statement = "select SUBNAME, REGCODE from Subscriptions group by SUBNAME;";

    printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);

    my $res = $dbh->selectall_hashref($statement, "REGCODE");

    foreach my $regcode (keys %{$res})
    {
        $statement = sprintf("SELECT COUNT(DISTINCT r.GUID) from Products p, Registration r where r.PRODUCTID=p.PRODUCTDATAID and p.PRODUCTDATAID IN (SELECT DISTINCT PRODUCTDATAID from ProductSubscriptions ps where ps.REGCODE = %s)", 
                             $dbh->quote($regcode));

        printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);
        
        my $count = $dbh->selectcol_arrayref($statement);
        
        if(exists $count->[0] && defined $count->[0])
        {
            $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES} = int $count->[0];
        }
    }

    #
    # Active Subscriptions
    #
    
    $statement  = "select REGCODE, SUBNAME, SUBSTATUS, SUM(NODECOUNT) as SUM_NODECOUNT, MIN(NODECOUNT) = -1 as UNLIMITED, MIN(SUBENDDATE) as MINENDDATE ";
    $statement .= "from Subscriptions where SUBSTATUS = 'ACTIVE' and (now()+interval 30 DAY) < SUBENDDATE ";
    $statement .= "group by SUBNAME order by SUBNAME;";
    
    printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);

    $res = $dbh->selectall_hashref($statement, "SUBNAME");

    my $tact = new Text::ASCIITable({ headingText => __("Active Subscriptions")." ($time)" });
    $tact->setCols(__('Subscription'), __('Node Count'), __('Assigned Machines'), __('Expiring Date'));

    foreach my $subname (keys %{$res})
    {
        my $assignedMachines = 0;
        my $nc = 0;
        
        if($res->{$subname}->{UNLIMITED})
        {
            $assignedMachines = int $calchash->{$subname}->{MACHINES};
            $calchash->{$subname}->{MACHINES} = 0;
            $nc = "unlimited";
        }
        else
        {
            $nc = (int $res->{$subname}->{SUM_NODECOUNT});
            if($nc >= (int $calchash->{$subname}->{MACHINES}))
            {
                $assignedMachines = $calchash->{$subname}->{MACHINES};
                $calchash->{$subname}->{MACHINES} = 0;
            }
            else
            {
                $assignedMachines = $nc;
                $calchash->{$subname}->{MACHINES} -= $nc;                
            }
        }
                
        $tact->addRow(
                      $res->{$subname}->{SUBNAME},
                      $nc,
                      $assignedMachines,
                      $res->{$subname}->{MINENDDATE}
                     );
    }
    $report .= $tact->draw()."\n";


    #
    # Expire soon
    #
    
    $statement  = "select REGCODE, SUBNAME, SUBSTATUS, SUM(NODECOUNT) as SUM_NODECOUNT, MIN(NODECOUNT) = -1 as UNLIMITED, MIN(SUBENDDATE) as MINENDDATE ";
    $statement .= "from Subscriptions where SUBSTATUS = 'ACTIVE' and (now()+interval 30 DAY) > SUBENDDATE ";
    $statement .= "group by SUBNAME order by SUBNAME;";
    
    printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);

    $res = $dbh->selectall_hashref($statement, "SUBNAME");

    my $tsoon = new Text::ASCIITable({ headingText => __("Subscriptions which expired within the next 30 days")." ($time)" });
    $tsoon->setCols(__('Subscription'), __('Node Count'), __('Assigned Machines'), __('Expiring Date'));

    foreach my $subname (keys %{$res})
    {
        my $assignedMachines = 0;
        my $nc = 0;
        
        if($res->{$subname}->{UNLIMITED})
        {
            $assignedMachines = $calchash->{$subname}->{MACHINES};
            $calchash->{$subname}->{MACHINES} = 0;
            $nc = "unlimited";
        }
        else
        {
            $nc = (int $res->{$subname}->{SUM_NODECOUNT});
            if($nc >= (int $calchash->{$subname}->{MACHINES}))
            {
                $assignedMachines = $calchash->{$subname}->{MACHINES};
                $calchash->{$subname}->{MACHINES} = 0;
            }
            else
            {
                $assignedMachines = $nc;
                $calchash->{$subname}->{MACHINES} -= $nc;                
            }
        }

        if($assignedMachines > 0)
        {
            $expireSoonMachines->{$subname} += int $assignedMachines;
        }
        
        $tsoon->addRow(
                       $res->{$subname}->{SUBNAME},
                       $nc,
                       $assignedMachines,
                       $res->{$subname}->{MINENDDATE}
                      );
    }
    $report .= $tsoon->draw()."\n";


    #
    # Expired Subscriptions
    #
    
    $statement  = "select REGCODE, SUBNAME, SUBSTATUS, SUM(NODECOUNT) as SUM_NODECOUNT, MIN(NODECOUNT) = -1 as UNLIMITED, MAX(SUBENDDATE) as MAXENDDATE ";
    $statement .= "from Subscriptions where SUBSTATUS = 'EXPIRED' ";
    $statement .= "group by SUBNAME order by SUBNAME;";
    
    printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);

    $res = $dbh->selectall_hashref($statement, "SUBNAME");

    my $texp = new Text::ASCIITable({ headingText => __("Expired Subscriptions")." ($time)" });
    $texp->setCols(__('Subscription'), __('Node Count'), __('Assigned Machines'), __('Expiring Date'));
    my $doDraw = 0;
    
    foreach my $subname (keys %{$res})
    {
        my $assignedMachines = 0;
        my $nc = 0;
        
        $assignedMachines = int $calchash->{$subname}->{MACHINES};

        if($res->{$subname}->{UNLIMITED})
        {
            $nc = "unlimited";
        }
        else
        {
            $nc = (int $res->{$subname}->{SUM_NODECOUNT});
        }

        next if($assignedMachines == 0);
        $doDraw = 1;

        $expiredMachines->{$subname} += int $assignedMachines;
        
        $texp->addRow(
                      $res->{$subname}->{SUBNAME},
                      $nc,
                      $assignedMachines,
                      $res->{$subname}->{MAXENDDATE}
                     );
    }
    if($doDraw)
    {
        $report .= $texp->draw()."\n";
    }
    
    $report .= __("Summary:\n");
    $report .=    "========\n\n";

    my $ok = 1;

    foreach my $subname (keys %{$expireSoonMachines})
    {
        if($expireSoonMachines->{$subname} > 0)
        {
            $report .= sprintf(__("%d Machines are assigned to '%s', which expires within the next 30 Days. Please renew the subscription.\n"), 
                               $expireSoonMachines->{$subname},
                               $subname);
            $ok = 0;
        }
    }

    foreach my $subname (keys %{$expiredMachines})
    {
        if($expiredMachines->{$subname} > 0)
        {
            $report .= sprintf(__("%d Machines are assigned to '%s', which is expired. Please renew the subscription.\n"), 
                               $expireSoonMachines->{$subname},
                               $subname);
            $ok = 0;
        }
    }

    if($ok)
    {
        $report .= __("The Subscription status is ok.\n");
    }    

    return $report;
}


sub subscriptionReport
{
    my %options = @_;
    my ($cfg, $dbh, $nuri) = init();
    my $report = "";
    
    my $debug = 0;
    $debug = $options{debug} if(exists $options{debug} && defined $options{debug});

    my $statement = "";
    my $time = SMT::Utils::getDBTimestamp();
    my $calchash = {};
    
    #
    # active subscriptions
    #

    $statement  = "select s.SUBNAME, s.REGCODE, s.NODECOUNT, s.SUBSTATUS, s.SUBENDDATE from Subscriptions s ";
    $statement .= "where s.SUBSTATUS = 'ACTIVE' and (now()+interval 30 DAY) < s.SUBENDDATE;";

    printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);

    my $res = $dbh->selectall_hashref($statement, "REGCODE");

    $statement  = "select s.REGCODE, COUNT(c.GUID) as MACHINES from Subscriptions s, ClientSubscriptions cs, Clients c ";
    $statement .= "where s.REGCODE = cs.REGCODE and cs.GUID = c.GUID and s.SUBSTATUS = 'ACTIVE' and ";
    $statement .= "(now()+interval 30 DAY) < s.SUBENDDATE group by REGCODE order by SUBENDDATE";

    printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);

    my $assigned = $dbh->selectall_hashref($statement, "REGCODE");

    foreach my $regcode (keys %{$assigned})
    {
        if(exists $res->{$regcode})
        {
            $res->{$regcode}->{MACHINES} = $assigned->{$regcode}->{MACHINES};
        }
    }
    
    my $tact = new Text::ASCIITable({ headingText => __("Active Subscriptions")." ($time)" });
    $tact->setCols(__('Subscription'),__('Registration Code'), __('Node Count'), __('Assigned Machines'), __('Expiring Date'));

    foreach my $regcode (keys %{$res})
    {
        if(!exists $calchash->{$res->{$regcode}->{SUBNAME}})
        {
            $calchash->{$res->{$regcode}->{SUBNAME}}->{NODECOUNT} = (int $res->{$regcode}->{NODECOUNT});
            $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES} = (exists $res->{$regcode}->{MACHINES})?(int $res->{$regcode}->{MACHINES}):0;
        }
        else
        {
            my $nc = $calchash->{$res->{$regcode}->{SUBNAME}}->{NODECOUNT};
            # nodecount == -1 means unlimited
            if($nc != -1)
            {
                if((int $res->{$regcode}->{NODECOUNT}) == -1)
                {
                    $nc = -1;
                }
                else
                {
                    $nc += (int $res->{$regcode}->{NODECOUNT});
                }
            }
            
            my $m = $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES};
            
            if(exists $res->{$regcode}->{MACHINES})
            {
                $m += (int $res->{$regcode}->{MACHINES});
            }
            
            $calchash->{$res->{$regcode}->{SUBNAME}}->{NODECOUNT} = $nc;
            $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES} = $m;
        }
        
        $tact->addRow(
                      $res->{$regcode}->{SUBNAME},
                      $res->{$regcode}->{REGCODE},
                      ($res->{$regcode}->{NODECOUNT} == -1)?"unlimited":$res->{$regcode}->{NODECOUNT},
                      (exists $res->{$regcode}->{MACHINES})?$res->{$regcode}->{MACHINES}:0,
                      $res->{$regcode}->{SUBENDDATE}
                     );
    }
    $report .= $tact->draw()."\n";

    #
    # expire soon 
    #
    $statement = "select s.SUBNAME, s.REGCODE, COUNT(c.GUID) as MACHINES, s.NODECOUNT, s.SUBSTATUS, s.SUBENDDATE from Subscriptions s, ClientSubscriptions cs, Clients c where s.REGCODE = cs.REGCODE and cs.GUID = c.GUID and s.SUBSTATUS = 'ACTIVE' and (now()+interval 30 DAY) > s.SUBENDDATE group by REGCODE order by SUBENDDATE;";
    
    printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);

    $res = $dbh->selectall_hashref($statement, "REGCODE");

    my $tsoon = new Text::ASCIITable({ headingText => __('Subscriptions which expiring within the next 30 Days')." ($time)" });
    $tsoon->setCols(__('Subscription'),__('Registration Code'), __('Node Count'), __('Assigned Machines'), __('Expiring Date'));
    
    foreach my $regcode (keys %{$res})
    {
        if(!exists $calchash->{$res->{$regcode}->{SUBNAME}})
        {
            $calchash->{$res->{$regcode}->{SUBNAME}}->{NODECOUNT} = (int $res->{$regcode}->{NODECOUNT});
            $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES} = (exists $res->{$regcode}->{MACHINES})?(int $res->{$regcode}->{MACHINES}):0;
        }
        else
        {
            my $nc = $calchash->{$res->{$regcode}->{SUBNAME}}->{NODECOUNT};
            # nodecount == -1 means unlimited
            if($nc != -1)
            {
                if((int $res->{$regcode}->{NODECOUNT}) == -1)
                {
                    $nc = -1;
                }
                else
                {
                    $nc += (int $res->{$regcode}->{NODECOUNT});
                }
            }

            my $m = $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES};
            if(exists $res->{$regcode}->{MACHINES})
            {
                $m += (int $res->{$regcode}->{MACHINES});
            }
            
            $calchash->{$res->{$regcode}->{SUBNAME}}->{NODECOUNT} = $nc;
            $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES} = $m;
        }

        $tsoon->addRow(
                       $res->{$regcode}->{SUBNAME},
                       $res->{$regcode}->{REGCODE},
                      ($res->{$regcode}->{NODECOUNT} == -1)?"unlimited":$res->{$regcode}->{NODECOUNT},
                       (exists $res->{$regcode}->{MACHINES})?$res->{$regcode}->{MACHINES}:0,
                       $res->{$regcode}->{SUBENDDATE}
                      );
    }
    $report .= $tsoon->draw()."\n";


    #
    # expired subscriptions
    #

    $statement = "select s.SUBNAME, s.REGCODE, COUNT(c.GUID) as MACHINES, s.NODECOUNT, s.SUBSTATUS, s.SUBENDDATE from Subscriptions s, ClientSubscriptions cs, Clients c where s.REGCODE = cs.REGCODE and cs.GUID = c.GUID and s.SUBSTATUS = 'EXPIRED' group by REGCODE order by SUBENDDATE;";
    
    printLog($options{log}, "debug", "STATEMENT: $statement") if ($debug);

    $res = $dbh->selectall_hashref($statement, "REGCODE");

    my $texp = new Text::ASCIITable({ headingText => __('Expired Subscriptions')." ($time)" });
    $texp->setCols(__('Subscription'),__('Registration Code'), __('Node Count'), __('Assigned Machines'), __('Expiring Date'));

    foreach my $regcode (keys %{$res})
    {

        if(!exists $calchash->{$res->{$regcode}->{SUBNAME}})
        {
            $calchash->{$res->{$regcode}->{SUBNAME}}->{NODECOUNT} = 0;
            $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES} = (exists $res->{$regcode}->{MACHINES})?(int $res->{$regcode}->{MACHINES}):0;
        }
        else
        {
            my $m = $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES};
            if(exists $res->{$regcode}->{MACHINES})
            {
                $m += (int $res->{$regcode}->{MACHINES});
            }
            
            $calchash->{$res->{$regcode}->{SUBNAME}}->{MACHINES} = $m;
        }

        $texp->addRow(
                      $res->{$regcode}->{SUBNAME},
                      $res->{$regcode}->{REGCODE},
                      ($res->{$regcode}->{NODECOUNT} == -1)?"unlimited":$res->{$regcode}->{NODECOUNT},
                      (exists $res->{$regcode}->{MACHINES})?$res->{$regcode}->{MACHINES}:0,
                       $res->{$regcode}->{SUBENDDATE}
                     );
    }
    $report .= $texp->draw()."\n";


    $report .= __("Summary:\n");
    $report .=    "========\n\n";

    my $ok = 1;
    
    foreach my $sn (keys %{$calchash})
    {
        if($calchash->{$sn}->{NODECOUNT} != -1 && $calchash->{$sn}->{NODECOUNT} < $calchash->{$sn}->{MACHINES})
        {
            $report .= sprintf(__("Not enough '%s' entitlements. Active entilements: %d  Assigned machines: %d "),
                               $sn,
                               $calchash->{$sn}->{NODECOUNT},
                               $calchash->{$sn}->{MACHINES});
            $ok = 0;
        }
    }

    if($ok)
    {
        $report .= __("The Subscription status is ok.\n");
    }    
   
    return $report;
}


sub _sha1sum
{
  my $file = shift;

  return undef if(! -e $file);

  open(FILE, "< $file") or do {
        return undef;
  };

  my $sha1 = Digest::SHA1->new;
  eval
  {
      $sha1->addfile(*FILE);
  };
  if($@)
  {
      return undef;
  }
  my $digest = $sha1->hexdigest();
  return $digest;
}


1;

=head1 NAME

 SMT::CLI - SMT common actions for command line programs

=head1 SYNOPSIS

  SMT::listProducts();
  SMT::listCatalogs();
  SMT::setupCustomCatalogs();

=head1 DESCRIPTION

Common actions used in command line utilities that administer the
SMT system.

=head1 METHODS

=over 4

=item listProducts

Shows products. Pass mirrorable => 1 to get only mirrorable
products. 0 for non-mirrorable products, or nothing to get all
products.

=item listRegistrations

Shows active registrations on the system.


=item setupCustomCatalogs

modify the database to setup catalogs create by the customer

=item setCatalogDoMirror

set the catalog mirror flag to enabled or disabled

Pass id => foo to select the catalog.
Pass enabled => 1 or enabled => 0
disabled => 1 or disabled => 0 are supported as well

=item catalogDoMirrorFlag

Pass id => foo to select the catalog.
true if the catalog is ser to be mirrored, false otherwise

=back

=back

=head1 AUTHOR

dmacvicar@suse.de

=head1 COPYRIGHT

Copyright 2007, 2008 SUSE LINUX Products GmbH, Nuernberg, Germany.

=cut

