package SMT::NCCRegTools;
use strict;

use LWP::UserAgent;
use URI;
use SMT::Parser::ListReg;
use SMT::Parser::Bulkop;
use SMT::Utils;
use XML::Writer;
use Crypt::SSLeay;
use File::Temp;
use DBI qw(:sql_types);

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
    $self->{LOG}   = undef;
    # Do _NOT_ set env_proxy for LWP::UserAgent, this would break https proxy support
    $self->{USERAGENT}  = undef; 
    $self->{AUTHUSER} = "";
    $self->{AUTHPASS} = "";

    $self->{SMTGUID} = SMT::Utils::getSMTGuid();

    $self->{NCCEMAIL} = "";

    $self->{DBH} = undef;

    $self->{TEMPDIR} = File::Temp::tempdir(CLEANUP => 1);

    $self->{FROMDIR} = undef;
    $self->{TODIR}   = undef;

    $self->{HAVE_BULKOP} = 0;  # set to 1 as soon as NCC has the implementation

    if(exists $opt{useragent} && defined $opt{useragent} && $opt{useragent})
    {
        $self->{USERAGENT} = $opt{useragent};
    }
    else
    {
        $self->{USERAGENT} = LWP::UserAgent->new(keep_alive => 1);
        $self->{USERAGENT}->default_headers->push_header('Content-Type' => 'text/xml');
        $self->{USERAGENT}->protocols_allowed( [ 'https'] );
        push @{ $self->{USERAGENT}->requests_redirectable }, 'POST';
    }
    
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
    else
    {
        $self->{DBH} = SMT::Utils::db_connect();
    }
    
    if(exists $opt{nccemail} && defined $opt{nccemail})
    {
        $self->{NCCEMAIL} = $opt{nccemail};
    }
    
    
    my ($ruri, $user, $pass) = SMT::Utils::getLocalRegInfos();
    
    $self->{URI}      = $ruri;
    $self->{AUTHUSER} = $user;
    $self->{AUTHPASS} = $pass;
    bless($self);
    
    return $self;
}

#
# return count of errors. 0 == success
#
sub NCCRegister
{
    my $self = shift;
    my $sleeptime = shift;
    
    my $errors = 0;
    
    if(! defined $self->{DBH} || !$self->{DBH})
    {
        printLog($self->{LOG}, "error", __("Database handle is not available."));
        return 1;
    }
    
    if(!defined $self->{NCCEMAIL} || $self->{NCCEMAIL} eq "")
    {
        printLog($self->{LOG}, "error", __("No email address for registration available."));
        return 1;
    }
    
    eval
    {
        my $guids = $self->{DBH}->selectcol_arrayref("SELECT DISTINCT GUID from Registration WHERE REGDATE > NCCREGDATE || NCCREGDATE IS NULL");

        if(@{$guids} > 0)
        {
            # we have something to register, check for random sleep value
            sleep(int($sleeptime));
            
            printLog($self->{LOG}, "info", sprintf("Register %s new clients.", $#{@$guids}+1 ));
        }

        my $output = "";
            
        my $writer;
        my $guidHash = {};
        if($self->{HAVE_BULKOP})
        {
            $writer = new XML::Writer(OUTPUT => \$output);
            $writer->xmlDecl("UTF-8");
            
            my %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
                     "client_version" => "1.2.3",
                     "lang" => "en");
            $writer->startTag("bulkop", %a);
        }
        
        my $regtimestring = SMT::Utils::getDBTimestamp();
        foreach my $guid (@{$guids})
        {
            $regtimestring = SMT::Utils::getDBTimestamp();
            my $products = $self->{DBH}->selectall_arrayref(sprintf("select p.PRODUCTDATAID, p.PRODUCT, p.VERSION, p.REL, p.ARCH from Products p, Registration r where r.GUID=%s and r.PRODUCTID=p.PRODUCTDATAID", $self->{DBH}->quote($guid)), {Slice => {}});

            my $regdata =  $self->{DBH}->selectall_arrayref(sprintf("select KEYNAME, VALUE from MachineData where GUID=%s", 
                                                                    $self->{DBH}->quote($guid)), {Slice => {}});
            
            $guidHash->{$guid} = $products;

            if(defined $regdata && ref($regdata) eq "ARRAY")
            {
                printLog($self->{LOG}, "debug", "Register '$guid'") if($self->{DEBUG});

                my $out = "";
                
                if(!$self->{HAVE_BULKOP})
                {
                    $out = $self->_buildRegisterXML($guid, $products, $regdata);

                    if(!defined $out || $out eq "")
                    {
                        printLog($self->{LOG}, "error", sprintf(__("Unable to generate XML for GUID: %s"). $guid));
                        $errors++;
                    next;
                    }
                    
                    my $ret = $self->_sendData($out, "command=register");
                    if(!$ret)
                    {
                        $errors++;
                        next;
                    }
                    
                    $ret = $self->_updateRegistration($guid, $products, $regtimestring);
                    if(!$ret)
                    {
                        $errors++;
                        next;
                    }
                }
                else
                {
                    $self->_buildRegisterXML($guid, $products, $regdata, $writer);
                }
            }
            else
            {
                printLog($self->{LOG}, "error", sprintf(__("Incomplete registration found. GUID:%s"), $guid));
                $errors++;
                next;
            }
        }

        if($self->{HAVE_BULKOP})
        {
            $writer->endTag("bulkop");

            if(!defined $output || $output eq "")
            {
                printLog($self->{LOG}, "error", __("Unable to generate XML"));
                $errors++;
                return $errors;
            }
            my $destfile = $self->{TEMPDIR}."/bulkop.xml";
            
            my $ret= $self->_sendData($output, "command=bulkop", $destfile);
            if(! $ret)
            {
                $errors++;
                return $errors;
            }
            
            $ret = $self->_updateRegistrationBulk($guidHash, $regtimestring, $destfile);
            if(!$ret)
            {
                $errors++;
                return $errors;
            }
        }
    };
    if($@)
    {
        printLog($self->{LOG}, "error", $@);
        $errors++;
    }
    return $errors;
}

#
# return count of errors. 0 == success
#
sub NCCListRegistrations
{
    my $self = shift;

    my $destfile = $self->{TEMPDIR};
    
    if(defined $self->{FROMDIR} && -d $self->{FROMDIR})
    {
        $destfile = $self->{FROMDIR}."/listregistrations.xml";
    }
    else
    {
        my $output = "";
        my %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
                 "lang" => "en",
                 "client_version" => "1.2.3");
        
        my $writer = new XML::Writer(OUTPUT => \$output);
        $writer->xmlDecl("UTF-8");
        $writer->startTag("listregistrations", %a);
        
        $writer->startTag("authuser");
        $writer->characters($self->{AUTHUSER});
        $writer->endTag("authuser");
        
        $writer->startTag("authpass");
        $writer->characters($self->{AUTHPASS});
        $writer->endTag("authpass");

        $writer->startTag("smtguid");
        $writer->characters($self->{SMTGUID});
        $writer->endTag("smtguid");

        $writer->endTag("listregistrations");
        
        if(defined $self->{TODIR} && $self->{TODIR} ne "")
        {
            $destfile = $self->{TODIR};
        }
    
        $destfile .= "/listregistrations.xml";
        my $ok = $self->_sendData($output, "command=listregistrations", $destfile);
    
        if(!$ok || !-e $destfile)
        {
            printLog($self->{LOG}, "error", "List registrations request failed.");
            return 1;
        }
        return 0;
    }
    
    if(defined $self->{TODIR} && $self->{TODIR} ne "")
    {
        return 0;
    }
    else
    {
        if(! defined $self->{DBH} || !$self->{DBH})
        {
            printLog($self->{LOG}, "error", __("Database handle is not available."));
            return 1;
        }
        
        my $sth = $self->{DBH}->prepare("SELECT DISTINCT GUID from Registration WHERE NCCREGDATE IS NOT NULL");
        #$sth->bind_param(1, '1970-01-02 00:00:01', SQL_TIMESTAMP);
        $sth->execute;
        my $guidhash = $self->{DBH}->fetchall_hashref();

        # The _listreg_handler fill the ClientSubscription table new.
        # Here we need to delete it first

        $self->{DBH}->do("DELETE from ClientSubscriptions");
        
        my $parser = new SMT::Parser::ListReg(log => $self->{LOG});
        $parser->parse($destfile, sub{ _listreg_handler($self, $guidhash, @_)});
    
        # $guidhash includes now a list of GUIDs which are no longer in NCC
        # A customer may have removed them via NCC web page. 
        # So remove them also here in SMT
        
        $self->_deleteRegistrationLocal(keys %{$guidhash});
        
        return 0;
    }
}

#
# return count of errors. 0 == success
#
sub NCCListSubscriptions
{
    my $self = shift;

    my $destfile = $self->{TEMPDIR};
    
    if(defined $self->{FROMDIR} && -d $self->{FROMDIR})
    {
        $destfile = $self->{FROMDIR}."/listsubscriptions.xml";
    }
    else
    {
        my $output = "";
        my %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
                 "lang" => "en",
                 "client_version" => "1.2.3");
        
        my $writer = new XML::Writer(OUTPUT => \$output);
        $writer->xmlDecl("UTF-8");
        $writer->startTag("listsubscriptions", %a);
        
        $writer->startTag("authuser");
        $writer->characters($self->{AUTHUSER});
        $writer->endTag("authuser");
        
        $writer->startTag("authpass");
        $writer->characters($self->{AUTHPASS});
        $writer->endTag("authpass");

        $writer->startTag("smtguid");
        $writer->characters($self->{SMTGUID});
        $writer->endTag("smtguid");

        $writer->endTag("listsubscriptions");
        
        if(defined $self->{TODIR} && $self->{TODIR} ne "")
        {
            $destfile = $self->{TODIR};
        }
    
        $destfile .= "/listsubscriptions.xml";
        my $ok = $self->_sendData($output, "command=listsubscriptions", $destfile);
    
        if(!$ok || !-e $destfile)
        {
            printLog($self->{LOG}, "error", "List subscriptions request failed.");
            return 1;
        }
        return 0;
    }
    
    if(defined $self->{TODIR} && $self->{TODIR} ne "")
    {
        return 0;
    }
    else
    {
        if(! defined $self->{DBH} || !$self->{DBH})
        {
            printLog($self->{LOG}, "error", __("Database handle is not available."));
            return 1;
        }
        
        # The _listsub_handler fill the Subscriptions and ProductSubscriptions table new.
        # Here we need to delete it first

        $self->{DBH}->do("DELETE from Subscriptions");
        $self->{DBH}->do("DELETE from ProductSubscriptions");
        
        my $parser = new SMT::Parser::ListSubscriptions(log => $self->{LOG});
        $parser->parse($destfile, sub{ _listsub_handler($self, @_)});
        
        return 0;
    }
}


#
# return count of errors. 0 == success
#
sub NCCDeleteRegistration
{
    my $self = shift;
    my @guids = @_;
    
    my $errors = 0;
    
    if(! defined $self->{DBH} || !$self->{DBH})
    {
        printLog($self->{LOG}, "error", __("Database handle is not available."));
        return 1;
    }

    # check if we are allowed to register clients at NCC
    # if no, we are also not allowed to remove them
    
    my $cfg = new Config::IniFiles( -file => "/etc/smt.conf" );
    if(!defined $cfg)
    {
        SMT::Utils::printLog($self->{LOG}, "error", sprintf(__("Cannot read the SMT configuration file: %s"), @Config::IniFiles::errors));
        return 1;
    }
    my $allowRegister = $cfg->val("LOCAL", "forwardRegistration");

    foreach my $guid (@guids)
    {
        $self->_deleteRegistrationLocal($guid);

        if(!(defined $allowRegister && $allowRegister eq "true"))
        {
            next;
        }
        
        # check if this client was registered at NCC
        my $sth = $self->{DBH}->prepare("SELECT GUID from Registration where NCCREGDATE IS NOT NULL and GUID=?");
        #$sth->bind_param(1, '1970-01-02 00:00:01', SQL_TIMASTAMP);
        $sth->bind_param(1, $guid);
        $sth->execute;
        my $result = $self->{DBH}->fetchrow_arrayref();

        if(!(exists $result->[0] && defined $result->[0] && $result->[0] eq $guid))
        {
            # this GUID was never registered at NCC 
            # no need to delete it there
            next;
        }        
        
        my $output = "";
        my %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
                 "lang" => "en",
                 "client_version" => "1.2.3");
        
        my $writer = new XML::Writer(OUTPUT => \$output);
        $writer->xmlDecl("UTF-8");
        $writer->startTag("de-register", %a);
        
        $writer->startTag("guid");
        $writer->characters($guid);
        $writer->endTag("guid");
        
        $writer->startTag("authuser");
            $writer->characters($self->{AUTHUSER});
        $writer->endTag("authuser");
        
            $writer->startTag("authpass");
        $writer->characters($self->{AUTHPASS});
        $writer->endTag("authpass");
        
        $writer->startTag("smtguid");
        $writer->characters($self->{SMTGUID});
        $writer->endTag("smtguid");

        $writer->endTag("de-register");
        
        my $ok = $self->_sendData($output, "command=de-register");
        
        if(!$ok)
        {
            printLog($self->{LOG}, "error", sprintf(__("Delete registration request failed: %s."), $guid));
            $errors++;
        }
    }
    
    return $errors;
}


###############################################################################
###############################################################################
###############################################################################
###############################################################################

sub _deleteRegistrationLocal
{
    my $self = shift;
    my @guids = @_;
    
    my $where = "";
    if(@guids == 0)
    {
        return 1;
    }
    elsif(@guids == 1)
    {
        $where = sprintf("GUID = %s", $self->{DBH}->quote( $guids[0] ) );
    }
    else
    {
        $where = sprintf("GUID IN ('%s')", join("','", @guids));
    }
        
    my $statement = "DELETE FROM Registration where ".$where;
    
    $self->{DBH}->do($statement);
    
    $statement = "DELETE FROM Clients where ".$where;

    $self->{DBH}->do($statement);
    
    $statement = "DELETE FROM MachineData where ".$where;
    
    $self->{DBH}->do($statement);
    
    #FIXME: does it make sense to remove this GUID from ClientSubscriptions ?

    return 1;
}


sub _listreg_handler
{
    my $self     = shift;
    my $guidhash = shift;
    my $data     = shift;
    
    my $statement = "";

    if(!exists $data->{GUID} || !defined $data->{GUID})
    {
        # should not happen, but it is better to check it
        return;
    }
    
    eval
    {
        # check if data->{GUID} exists localy
        if(exists $guidhash->{$data->{GUID}})
        {
            delete $guidhash->{$data->{GUID}};
            
            foreach my $regcode (@{$data->{SUBREF}})
            {
                $statement = sprintf("INSERT INTO ClientSubscriptions (GUID, REGCODE) VALUES(%s, %s)", 
                                     $self->{DBH}->quote($data->{GUID}),
                                     $self->{DBH}->quote($regcode));
                
                $self->{DBH}->do($statement);
            }
        }
        else
        {
            # We found a registration from SMT in NCC which does not exist in SMT anymore
            # print and error. The admin has to delete it in NCC by hand.
            printLog($self->{LOG}, "error", sprintf(__("WARNING: Found a subscription in NCC which is not available here: '%s'"), $data->{GUID}));
        }
    };
    if($@)
    {
        printLog($self->{LOG}, "error", $@);
        return;
    }
    return;
}

sub _bulkop_handler
{
    my $self          = shift;
    my $data          = shift;
    my $guidHash      = shift;
    my $regtimestring = shift; 

    if(!exists $data->{GUID} || ! defined $data->{GUID} || $data->{GUID} eq "")
    {
        # something goes wrong
        return;
    }
    my $guid = $data->{GUID};
 
    # evaluate the status

    if(! exists $data->{STATUS} || ! defined $data->{STATUS} || $data->{STATUS} eq "")
    {
        # something goes wrong
        return;
    }
    
    if($data->{STATUS} eq "error")
    {
        printLog($self->{LOG}, "error", 
                 sprintf(__("Registration of GUID '%s' failed. %s"), $guid, $data->{MESSAGE}));
        return;
    }
    elsif($data->{STATUS} eq "warning")
    {
        printLog($self->{LOG}, "warn", $data->{MESSAGE});
    }
    # else success
   
    if(!exists $guidHash->{$guid} || ! defined $guidHash->{$guid} || ref($guidHash->{$guid}) ne "ARRAY")
    {
        # something goes wrong
        return;
    }
 
    my @productids = ();
    foreach my $prod (@{$guidHash->{$guid}})
    {
        if( exists $prod->{PRODUCTDATAID} && defined $prod->{PRODUCTDATAID} )
        {
            push @productids, $prod->{PRODUCTDATAID};
        }
    }
    
    my $statement = "UPDATE Registration SET NCCREGDATE=? WHERE GUID=%s and ";
    if(@productids > 1)
    {
        $statement .= "PRODUCTID IN (".join(",", @productids).")";
    }
    elsif(@productids == 1)
    {
        $statement .= "PRODUCTID = ".$productids[0];
    }
    else
    {
        # this should not happen
        printLog($self->{LOG}, "error", __("No products found."));
        return 0;
    }
    my $sth = $self->{DBH}->prepare(sprintf("$statement", $self->{DBH}->quote($guid)));
    $sth->bind_param(1, $regtimestring, SQL_TIMESTAMP);
    $sth->execute;
}


sub _listsub_handler
{
    my $self     = shift;
    my $data     = shift;
    
    my $statement = "";

    if(!exists $data->{REGCODE} || !defined $data->{REGCODE} || $data->{REGCODE} eq "" ||
       !exists $data->{NAME} || !defined $data->{NAME} || $data->{NAME} eq "" ||
       !exists $data->{STATUS} || !defined $data->{STATUS} || $data->{STATUS} eq "" ||
       !exists $data->{ENDDATE} || !defined $data->{ENDDATE} || $data->{ENDDATE} eq "" ||
       !exists $data->{PRODUCTLIST} || !defined $data->{PRODUCTLIST} || $data->{PRODUCTLIST} eq "" ||
       !exists $data->{NODECOUNT} || !defined $data->{NODECOUNT} || $data->{NODECOUNT} eq "")
    {
        # should not happen, but it is better to check it
        printLog($self->{LOG}, "error", "ListRegistrations: incomplete data set. Skip");
        return;
    }
    
    eval
    {
        # FIXME: We may need to convert the date types
        $statement =  "INSERT INTO SUBSCRIPTIONS (REGCODE, SUBNAME, SUBTYPE, SUBSTATUS, SUBSTARTDATE, SUBENDDATE, SUBDURATION, SERVERCLASS, NODECOUNT) ";
        $statement .= "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)";
        
        my $sth = $self->{DBH}->prepare($statement);
        $sth->bind_param(1, $data->{REGCODE});
        $sth->bind_param(2, $data->{NAME});
        $sth->bind_param(3, $data->{TYPE});
        $sth->bind_param(4, $data->{STATUS});
        $sth->bind_param(5, $data->{STARTDATE}, SQL_TIMESTAMP);
        $sth->bind_param(6, $data->{ENDDATE}, SQL_TIMESTAMP);
        $sth->bind_param(7, $data->{DURATION}, SQL_INTEGER);
        $sth->bind_param(8, $data->{SERVERCLASS});
        $sth->bind_param(9, $data->{NODECOUNT}, SQL_INTEGER);
        
        my $res = $sth->execute;
        
        printLog($self->{LOG}, "debug", $sth->{Statement}." :$res");
        
        my @productids = split(/\s*,\s*/, $data->{PRODUCTLIST});
        
        foreach my $id (@productids)
        {
            $statement = sprintf("INSERT INTO ProductSubscriptions (PRODUCTDATAID, REGCODE) VALUES (%s, %s)",
                                 $id, $self->{DBH}->quote($data->{REGCODE}));

            my $res = $self->{DBH}->do($statement);
            printLog($self->{LOG}, "debug", "$statement :$res");
        }
    };
    if($@)
    {
        printLog($self->{LOG}, "error", $@);
        return;
    }
    return;
}


sub _updateRegistration
{
    my $self          = shift || undef;
    my $guid          = shift || undef;
    my $products      = shift || undef;
    my $regtimestring = shift || undef;
    
    if(!defined $guid)
    {
        printLog($self->{LOG}, "error", __("Invalid GUID"));
        return 0;
    }
    
    if(!defined $products || ref($products) ne "ARRAY")
    {
        printLog($self->{LOG}, "error", __("Invalid Products"));
        return 0;
    }
    
    if(!defined $regtimestring)
    {
        printLog($self->{LOG}, "error", __("Invalid time string"));
        return 0;
    }
    
    my @productids = ();
    foreach my $prod (@{$products})
    {
        if( exists $prod->{PRODUCTDATAID} && defined $prod->{PRODUCTDATAID} )
        {
            push @productids, $prod->{PRODUCTDATAID};
        }
    }
    
    my $statement = "UPDATE Registration SET NCCREGDATE=? WHERE GUID=%s and ";
    if(@productids > 1)
    {
        $statement .= "PRODUCTID IN (".join(",", @productids).")";
    }
    elsif(@productids == 1)
    {
        $statement .= "PRODUCTID = ".$productids[0];
    }
    else
    {
        # this should not happen
        printLog($self->{LOG}, "error", __("No products found."));
        return 0;
    }
    my $sth = $self->{DBH}->prepare(sprintf("$statement", $self->{DBH}->quote($guid)));
    $sth->bind_param(1, $regtimestring, SQL_TIMESTAMP);
    return $sth->execute;
    
    #return $self->{DBH}->do(sprintf($statement, $self->{DBH}->quote($regtimestring), $self->{DBH}->quote($guid)));
}

sub _updateRegistrationBulk
{
    my $self          = shift || undef;
    my $guidHash      = shift || undef;
    my $regtimestring = shift || undef;
    my $respfile      = shift || undef;
    
    if(!defined $guidHash)
    {
        printLog($self->{LOG}, "error", __("Invalid GUIDHASH parameter"));
        return 0;
    }
    
    if(!defined $regtimestring)
    {
        printLog($self->{LOG}, "error", __("Invalid time string"));
        return 0;
    }

    if(! defined $respfile || ! -e $respfile)
    {
        printLog($self->{LOG}, "error", __("Invalid server response"));
        return 0;
    }
     

    # A parser for the answer is required here and everything below this comment
    # should be part of the handler
   
    my $parser = new SMT::Parser::Bulkop(log => $self->{LOG});
    $parser->parse($respfile, sub{ _bulkop_handler($self, $guidHash, $regtimestring, @_)});

    return 1;
}


sub _sendData
{
    my $self = shift || undef;
    my $data = shift || undef;
    my $query = shift || undef;
    my $destfile = shift || undef;
    
    my $defaultquery = "lang=en-US&version=1.0";

    if (! defined $self->{URI})
    {
        printLog($self->{LOG}, "error", __("Cannot send data to registration server. Missing URL."));
        return 0;
    }
    if($self->{URI} =~ /^-/)
    {
        printLog($self->{LOG}, "error", sprintf(__("Invalid protocol(%s)."), $self->{URI}));
        return 0;
    }

    my $regurl = URI->new($self->{URI});
    if(defined $query && $query =~ /\w=\w/)
    {
        $regurl->query($query."&".$defaultquery);
    }
    else
    {
        $regurl->query($defaultquery);
    }    

    printLog($self->{LOG}, "debug", "SEND TO: ".$regurl->as_string()) if($self->{DEBUG});
    printLog($self->{LOG}, "debug", "XML:\n$data") if($self->{DEBUG});

    # FIXME: we need to delete this as soon as NCC provide these features
    return 1;

    my %params = ('Content' => $data);
    if(defined $destfile && $destfile ne "")
    {
        $params{':content_file'} = $destfile;
    } 
    
    my $response = $self->{USERAGENT}->post( $regurl->as_string(), %params);
    
    if($response->is_success)
    {
        return 1;
    }
    else
    {
        printLog($self->{LOG}, "error", $response->status_line);
        return 0;
    }
}


sub _buildRegisterXML
{
    my $self     = shift;
    my $guid     = shift;
    my $products = shift;
    my $regdata  = shift;
    my $writer   = shift;
    
    my $output = "";
    my %a = ();
    if(! defined $writer || !$writer)
    {
        $writer = new XML::Writer(OUTPUT => \$output);
        $writer->xmlDecl("UTF-8");
    
        %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
              "lang" => "en",
              "client_version" => "1.2.3");
    }
    
    $a{force} = "batch";
    
    $writer->startTag("register", %a);

    $writer->startTag("guid");
    $writer->characters($guid);
    $writer->endTag("guid");

    foreach my $pair (@{$regdata})
    {
        if($pair->{KEYNAME} eq "host")
        {
            if(defined $pair->{VALUE} && $pair->{VALUE} ne "")
            {
                $writer->startTag("host");
                $writer->characters($pair->{VALUE});
                $writer->endTag("host");
            }
            else
            {
                $writer->emptyTag("host");
            }
            last;
        }
    }
    
    $writer->startTag("authuser");
    $writer->characters($self->{AUTHUSER});
    $writer->endTag("authuser");

    $writer->startTag("authpass");
    $writer->characters($self->{AUTHPASS});
    $writer->endTag("authpass");
    
    $writer->startTag("smtguid");
    $writer->characters($self->{SMTGUID});
    $writer->endTag("smtguid");
    
    foreach my $PHash (@{$products})
    {
        if(defined $PHash->{PRODUCT} && $PHash->{PRODUCT} ne "" &&
           defined $PHash->{VERSION} && $PHash->{VERSION} ne "")
        {
            $writer->startTag("product",
                              "version" => $PHash->{VERSION},
                              "release" => (defined $PHash->{REL})?$PHash->{REL}:"",
                              "arch"    => (defined $PHash->{ARCH})?$PHash->{ARCH}:"");
            if ($PHash->{PRODUCT} =~ /\s+/)
            {
                $writer->cdata($PHash->{PRODUCT});
            }
            else
            {
                $writer->characters($PHash->{PRODUCT});
            }
            $writer->endTag("product");
        }
    }

    my $foundEmail = 0;
    
    foreach my $pair (@{$regdata})
    {
        next if($pair->{KEYNAME} eq "host");
        
        if(!defined $pair->{VALUE})
        {
            $pair->{VALUE} = "";
        }

        if($pair->{KEYNAME} eq "email" )
        {
            if($pair->{VALUE} ne "")
            {
                $foundEmail = 1;
            }
            else
            {
                $foundEmail = 1;
                $pair->{VALUE} = $self->{NCCEMAIL};
            }
        }
                
        if($pair->{VALUE} eq "")
        {
            $writer->emptyTag("param", "id" => $pair->{KEYNAME});
        }
        else
        {
            $writer->startTag("param",
                              "id" => $pair->{KEYNAME});
            if ($pair->{VALUE} =~ /\s+/)
            {
                $writer->cdata($pair->{VALUE});
            }
            else
            {
                $writer->characters($pair->{VALUE});
            }
            $writer->endTag("param");
        }
    }

    if(!$foundEmail)
    {
        $writer->startTag("param",
                          "id" => "email");
        $writer->characters($self->{NCCEMAIL});
        $writer->endTag("param");
    }
    
    $writer->endTag("register");

    return $output;
}

1;
