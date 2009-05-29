package SMT::RESTService;

use strict;
use warnings;

use APR::Brigade ();
use APR::Bucket ();
use APR::Const     -compile => qw(:error SUCCESS BLOCK_READ);
use constant IOBUFSIZE => 8192;
use Apache2::Filter ();

use APR::Brigade;


use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Access ();

use Apache2::Const -compile => qw(OK SERVER_ERROR HTTP_UNAUTHORIZED NOT_FOUND FORBIDDEN AUTH_REQUIRED MODE_READBYTES :log);
use Apache2::RequestUtil;


use XML::Writer;

use SMT::Utils;
use SMT::JobQueue;
use SMT::Job;
use DBI qw(:sql_types);
use Data::Dumper;

#
# handle all GET requests
#
sub GEThandler($)
{
    my $r = shift;
    return undef unless defined $r;

    my $path = $r->path_info();
    # crop the prefix and trailing slash -  '/=' rest service identifier, '/1' version number
    # there is only version 1 so far
    $path =~ s/^\/(=\/)?1\///;
    $path =~ s/\/?$//;

    # TODO: read $guid 
    my $guid="guid12";

    # jobs (per client)
    my $reJobs     = qr{^jobs(/?\@all)?$};    # get list of all MY jobs
    my $reJobsNext = qr{^jobs/\@next$};       # get MY next job
    my $reJobsId   = qr{^jobs/([\d]+)$};      # get MY next job information
    # clients
    my $reClients           = qr{^clients(/?\@all)?$};                 # get list of all clients
    my $reClientsId         = qr{^clients/([\w]+)$};                   # get client information
    # clients/jobs
    my $reClientsAllJobs    = qr{^clients/\@all/jobs(/?\@all)?$};      # get list of jobs of all clients
    my $reClientsIdJobs     = qr{^clients/([\w]+)/jobs(/?\@all)?$};    # get list of jobs of one client
    my $reClientsIdJobsNext = qr{^clients/([\w]+)/jobs/\@next$};       # get next job for one client
    my $reClientsIdJobsId   = qr{^clients/([\w]+)/jobs/(\d+)$};        # get job information of one job for one client
    # clients/patchstatus
    my $reClientsIdPatchstatus  = qr{^clients/([\d\w]+)/patchstatus$}; # get patchstatus info for one client
    my $reClientsAllPatchstatus = qr{^clients/\@all/patchstatus$};     # get patchstatus info for all clients

    # jobs
    if    ( $path =~ $reJobs)           { return SMT::JobQueue->getJobList( $guid, 1 ) }
    elsif ( $path =~ $reJobsNext )      { return SMT::JobQueue->getJob( $guid, SMT::JobQueue->getNextJobID($guid, 0), 1)   }
    elsif ( $path =~ $reJobsId)         { return SMT::JobQueue->getJob( $guid, $1, 1 ) }
    elsif ( $path =~ $reClients )       { return "wanna all clients"; }
    elsif ( $path =~ $reClientsId )     { return "wanna one client with id: $1"; }
    elsif ( $path =~ $reClientsAllJobs )        { return "wanna list of all jobs of all clients"; }
    elsif ( $path =~ $reClientsIdJobs )         { return "wanna all jobs of one client with id $1"; }
    elsif ( $path =~ $reClientsIdJobsNext )     { return "wanna next job for one client with id $1"; }
    elsif ( $path =~ $reClientsIdJobsId )       { return "wanna job info of one job with id $2 for one client with id $1"; }
    elsif ( $path =~ $reClientsIdPatchstatus )  { return "wanna have patchstatus information for for one client with id $1"; }
    elsif ( $path =~ $reClientsAllPatchstatus ) { return "wanna have patchstatus information for all clients"; }
    else
    {
        $r->log->error("Request to undefined REST handler ($path) with method GET");
        return undef;
    }
};


sub POSThandler($)
{
    my $r = shift;
    return undef unless defined $r;

    return "this is the POST handler"; 
}



sub PUThandler($)
{
    my $r = shift;
    return undef unless defined $r;

    my $guid="guid12";

    my $path = $r->path_info();
    $path =~ s/^\/(=\/)?1\///;
    $path =~ s/\/?$//;

    my $reJobsId   = qr{^jobs/([\d]+)$};

    if ( $path =~ $reJobsId )
    {
	# TODO: check content type
	my $c = read_post($r);
	return SMT::JobQueue->updateJob($guid, $c);
    }
    else
    {
        $r->log->error("Request to undefined REST handler ($path) with method PUT.");
        return undef;
    }
}


sub DELETEhandler($)
{
    my $r = shift;
    return undef unless defined $r;
    return "this is the DELETE handler";
}




sub handler {
    use Switch;
    my $r = shift;
    $r->log->info("REST service request");

    # try to connect to the database - else report server error
    #my $dbh = undef;
    #if ( ! ($dbh=SMT::Utils::db_connect()) ) 
    #{
    #    $r->log->error("Could not connect to database.");
    #    return Apache2::Const::SERVER_ERROR; 
    #}

    my $res = undef;

    switch( $r->method() )
    {
        case /^GET$/i     { $res = GEThandler($r) }
        # is HEAD really needed ? does it make sense?
        case /^HEAD$/i    { $res = GEThandler($r) }
        case /^PUT$/i     { $res = PUThandler($r) }
        case /^POST$/i    { $res = POSThandler($r) }
        case /^DELETE$/i  { $res = DELETEhandler($r) }
        else
        {
            $r->log->error("Unknown request method in SMT rest service.");
            return Apache2::Const::NOT_FOUND
        }
    }

    if (not defined $res)
    {
        # errors are logged in method handlers
        return Apache2::Const::NOT_FOUND;
    }
    else
    {
        $r->content_type('text/xml');
        # $r->content_type('text/plain');
        $r->err_headers_out->add('Cache-Control' => "no-cache, public, must-revalidate");
        $r->err_headers_out->add('Pragma' => "no-cache");

        print $res;
    }


    # output some data for testing
    if (0) {
        my $writer = new XML::Writer(NEWLINES => 0);
        $writer->xmlDecl("UTF-8");

        $writer->startTag("jobs4smt");
        $writer->emptyTag('onejob',
                          'id'   =>  42,
                          'method'   => $r->method(),
                          'pathinfo' => $r->path_info(),
                          'unparsed_uri' => $r->unparsed_uri(),
                          'user'         => $r->user(),
                          'args'         => $r->args()
                     );
        $writer->startTag('resultdata');
        $writer->characters("$res");
        $writer->endTag('resultdata');
        $writer->endTag("jobs4smt");
        $writer->end();
    }

    return Apache2::Const::OK;
}






#
# read the content of a POST and return the data
#
sub read_post {
    my $r = shift;

    my $bb = APR::Brigade->new($r->pool,
                               $r->connection->bucket_alloc);

    my $data = '';
    my $seen_eos = 0;
    do {
        $r->input_filters->get_brigade($bb, Apache2::Const::MODE_READBYTES,
                                       APR::Const::BLOCK_READ, IOBUFSIZE);

        for (my $b = $bb->first; $b; $b = $bb->next($b)) {
            if ($b->is_eos) {
                $seen_eos++;
                last;
            }

            if ($b->read(my $buf)) {
                $data .= $buf;
            }

            $b->remove; # optimization to reuse memory
        }

    } while (!$seen_eos);

    $bb->destroy;

    $r->log->info("Got content: $data");

    return $data;
}






1;
