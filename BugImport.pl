#!/usr/bin/perl

use strict;
use XML::Simple;
use lib qw(/var/www/html);
use AppD_Import;
use Getopt::Long;
use File::Basename qw(dirname);
use HTTP::Cookies;
use XMLRPC::Lite;
use VMware::ImportExternal;
use Data::Dumper;
use Bugzilla;
use Bugzilla::Util qw(lsearch);
use HTML::Strip;

my $options = {};

my $really_do=1;

my $Bugzilla_login;
my $Bugzilla_password;
my $Bugzilla_remember;

GetOptions("data_file=s"    => \$options->{'data_file'},
           'uri=s'          => \$options->{'uri'},
           'login:s'        => \$Bugzilla_login,
           'password=s'     => \$Bugzilla_password,
           'rememberlogin!' => \$Bugzilla_remember,

);

# First set up the nescessary XMLRPC items that will be needed
# to use the web services after all the data is parsed.

# Open our cookie jar so we only have to login once.

my $cookie_jar =
    new HTTP::Cookies('file' => File::Spec->catdir(dirname($0), 'cookies.txt'),
                      'autosave' => 1);
die "--uri must be specified - you probably want something like:\n --uri=https://gargv-bz3.eng.vmware.com/xmlrpc.cgi\n" unless $options->{'uri'};

my $proxy = XMLRPC::Lite->proxy($options->{'uri'},
                                'cookie_jar' => $cookie_jar);

if (defined($Bugzilla_login)) {
    if ($Bugzilla_login ne '') {
        # Log in.
        my $soapresult = $proxy->call('User.login',
                                   { login => $Bugzilla_login,
                                     password => $Bugzilla_password,
                                     remember => $Bugzilla_remember } );
        _die_on_fault($soapresult);
        print "Login successful.\n";
    }
    else {
        # Log out.
        my $soapresult = $proxy->call('User.logout');
        _die_on_fault($soapresult);
        print "Logout successful.\n";
    }
}

my $dbh = Bugzilla->dbh;
my ($timestamp) = $dbh->selectrow_array("SELECT NOW()");

my $product_name = 'Application Director 6.0 (sandbox)';

my $imported_already = $dbh->selectcol_arrayref("select external_id from imported_bug_id_map join products on products.id=imported_bug_id_map.product_id and name = '$product_name';");

my $bugzilla_col = {
   'priority' => 'severity',
   'summary' => 'summary',
   'status' => 'status',
   'resolution' => 'resolution',
   'description' => 'description',
   'component' => 'category',
   'reporter' => 'reporter',
   'assignee' => 'assigned_to',
   'created' => 'creation_ts',
   'updated' => 'delta_ts',
   'environment' => 'host_op_sys',
   'version' => 'found_in_version',
   'fixVersion' => 'fix_by',
   'type' => 'bug_type',
   'due' =>'cf_eta',
   'comments' => 'comment',
};
my $ref = XMLin($options->{'data_file'}, KeyAttr => ['rss']);
warn "Done reading XML\n";

my $bug_data;
my $column_data;
my $converted_data;
my $user_data;

foreach my $item (@{$ref->{'channel'}->{'item'}}) {
    my $external_id = '';
    my $defect_data;

    my $import_comment = '';
    my @additional_fields = ();
    foreach my $field (keys %$item) {
        if ($field eq 'title' ) {
            $external_id = $item->{'title'};
            $external_id =~ s/\[(.*?)-(.*?)\](.*)/$2/g;
        } elsif ($field eq 'priority') {
            $defect_data->{$bugzilla_col->{$field}}= convert_severity($item->{$field}->{'content'});
        } elsif ( $field eq 'summary' ){
            $defect_data->{$bugzilla_col->{$field}} = strip_chars($item->{$field});
        }elsif ( $field eq 'status') {
            $defect_data->{$bugzilla_col->{$field}} = $item->{$field}->{'content'};
        }elsif ( $field eq 'resolution' ){
            $defect_data->{$bugzilla_col->{$field}} = $item->{$field}->{'content'};
        }elsif ( $field eq 'description' ){
            my $desc = strip_chars($item->{$field});
            $defect_data->{$bugzilla_col->{$field}} = html_to_ascii($desc);
        }elsif ( $field eq 'component' ){
            $defect_data->{$bugzilla_col->{$field}} = $item->{$field};
        }elsif ( $field eq 'version' ){
            $defect_data->{'found_in_product'} = $product_name;
            my $value = $item->{$field};
            chomp($value);
            my $phase = $value;
            my $version = convert_version($value);
            $defect_data->{$bugzilla_col->{$field}} = $version;
            $defect_data->{'found_in_phase_id'} = convert_phase($phase, $version, $product_name);
        }elsif ($field eq 'fixVersion' ){
            foreach my $value (@{$item->{$field}}){
                my $phase = $value;
                my $fix_by_version = convert_version($value);
                my $fix_by = {'fix_by_product' => $product_name,'fix_by_version' => $fix_by_version , 'fix_by_phase_id' => convert_phase($phase,$fix_by_version,$product_name)};
                push(@{$defect_data->{'fix_by'}}, $fix_by);
            }
        }elsif ( $field eq 'environment' ){
            if ( ref $item->{$field} ne 'HASH'){
                $defect_data->{$bugzilla_col->{$field}} = $item->{$field};
            }else {
                $defect_data->{$bugzilla_col->{$field}} = '';
            }
        }elsif ( $field eq 'created' ){
            $defect_data->{$bugzilla_col->{$field}} = convert_date($item->{$field});
        }elsif ( $field eq 'updated' ){
            $defect_data->{$bugzilla_col->{$field}} = convert_date($item->{$field});
        }elsif ($field eq 'reporter' ){
            my $reporter = convert_username($item->{$field}->{'content'});
            if ($reporter ne 'False'){
                $defect_data->{$bugzilla_col->{$field}} = $reporter;
                $defect_data->{'qa_contact'} = $reporter;
            }else {
                print "User $item->{$field}->{'content'} does not exist for $field for bug id $external_id.\n";
                exit;
            }
        }elsif ($field eq 'assignee' ){
            my $assigned_to = convert_username($item->{$field}->{'content'});
            if ( $assigned_to ne 'False' ){
                $defect_data->{$bugzilla_col->{$field}} = $assigned_to;
            }else {
                print "User $item->{$field}->{'content'} does not exist for $field for bug id $external_id.\n";
                exit;
            }
        }elsif ( $field eq 'type' ){
            $defect_data->{$bugzilla_col->{$field}} = $item->{$field}->{'content'};
        }elsif ( $field eq 'due' ){
            if ( ref $item->{$field} ne 'HASH'){
                $defect_data->{$bugzilla_col->{$field}} = $item->{$field};
            }else {
                $defect_data->{$bugzilla_col->{$field}} = '';
            }
        }elsif ( $field eq 'comments' ){
            #$defect_data->{$bugzilla_col->{$field}} = $item->{$field}->{'comment'};
            my $value = {};
            $value = $item->{$field};
            #$value = strip_chars($item->{$field});
            foreach my $keys (%{$value}){
                if ( ref $value->{$keys} eq 'HASH' ){
                    my $who = $value->{$keys}->{'author'};
                    my $when=convert_date($value->{$keys}->{'created'});
                    my $text = html_to_ascii($value->{$keys}->{'content'});
                    if ($text){
                        my $comment = {'when' => $when,
                                       'who' => $who,
                                       'text' => $text};
                        push(@{$bug_data->{$external_id}->{'comments'}},$comment) if defined $bug_data->{$external_id};
                    }
                }else {
                    foreach my $arr (@{$value->{$keys}}){
                        my $who = $arr->{'author'};
                        my $when=convert_date($arr->{'created'});
                        my $text = html_to_ascii($arr->{'content'});
                        if ($text){
                            my $comment = {'when' => $when,
                                           'who' => $who,
                                           'text' => $text};
                            push(@{$bug_data->{$external_id}->{'comments'}},$comment) if defined $bug_data->{$external_id};
                       }#end if
                    }#end inside else foreach
                }#end else
            }#end outer foreach
        }#end elsif
         $bug_data->{$external_id} = $defect_data;
    }
    my $customfield = $item->{'customfields'};
    foreach my $branch (%{$customfield}){
        foreach my $custom (@{$customfield->{$branch}}){
            if ( $custom->{'customfieldname'} eq 'Cc' ){
                my $cc = validate_username($custom->{'customfieldvalues'}->{'customfieldvalue'});
                if ( $cc ne '' ){
                    push(@{$bug_data->{$external_id}->{'cc'}},$cc) if defined $bug_data->{$external_id};
                }else {
                    print "CC Field value $custom->{'customfieldvalues'}->{'customfieldvalue'} does not exist for Bug Id $external_id. Please check\n";
                    exit;
                }
            }# end of if
        }#end of inner foreach
    }#end of outer foreach
}
print Dumper $bug_data;

sub _die_on_fault {
    my $soapresult = shift;

    if ($soapresult->fault) {
        my ($package, $filename, $line) = caller;
        warn $soapresult->faultcode . ' ' . $soapresult->faultstring .
            " in SOAP call near $filename line $line.\n";
    }
}
