#!/usr/local/cpanel/3rdparty/bin/perl

# vm_setup.pl

use strict;
use warnings;
use Getopt::Long;
use Fcntl;
use IO::Handle;
use IO::Select;
use String::Random;
use IPC::Open3;
use Term::ANSIColor qw(:constants);

# reset colors to default when done
$Term::ANSIColor::AUTORESET = 1;

my $VERSION = '1.0.2';

# declare variables for script options and handle them
my ( $help, $verbose, $full, $fast, $force, $cltrue );
GetOptions(
    "help"      => \$help,
    "verbose"   => \$verbose,
    "full"      => \$full,
    "fast"      => \$fast,
    "force"     => \$force,
    "installcl" => \$cltrue,
);

# declare global variables for script
# both of these variables are used during the CL install portion
# of script and their necessity should be reviewed during TECH-407
my $VMS_LOG = '/var/log/vm_setup.log';

my $InstPHPSelector = 0;
my $InstCageFS      = 0;

# print header
print "\n";
print_vms("VM Server Setup Script");
print_vms("Version: $VERSION\n");

# help option should be processed first to ensure that nothing is erroneously executed if this option is passed
# converted this to a function to make main less clunky and it may be of use if we add more script arguments in the future
#  ex:  or die print_help_and_exit();
if ($help) {
    print_help_and_exit();
}

# vm_setup depends on multiple cPanel api calls
# if the license is invalid, we should immediately die
check_license();

# we should check for the lock file and exit if force argument not passed right after checking for help
# to ensure that no work is performed in this scenario
handle_lock_file();

create_vms_log_file();

setup_resolv_conf();

install_packages();
set_screen_perms();

# '/vat/cpanel/cpnat' is sometimes populated with incorrect IP information
# on new openstack builds
# build cpnat to ensure that '/var/cpanel/cpnat' has the correct IPs in it
print_vms("Building cpnat");
system_formatted("/usr/local/cpanel/scripts/build_cpnat");

# use a hash for system information
my %sysinfo = (
    "ostype"    => undef,
    "osversion" => undef,
    "tier"      => undef,
    "hostname"  => undef,
    "ip"        => undef,
    "natip"     => undef,
);

# hostname is in the format of 'os.cptier.tld'
get_sysinfo( \%sysinfo );

my $hostname = $sysinfo{'hostname'};
my $natip    = $sysinfo{'natip'};
my $ip       = $sysinfo{'ip'};

# set hostname
print_vms("Setting hostname to $hostname");

# use whmapi1 to set hostname so that we get a return value
# this will be important when we start processing output to ensure these calls succeed
# https://documentation.cpanel.net/display/SDK/WHM+API+1+Functions+-+sethostname
system_formatted("/usr/local/cpanel/bin/whmapi1 sethostname hostname=$hostname");

# edit files with the new hostname
configure_99_hostname_cfg($hostname);
configure_sysconfig_network($hostname);
configure_wwwacct_conf( $hostname, $natip );
configure_mainip($natip);
configure_whostmgrft();    # this is really just touching the file in order to skip initial WHM setup
configure_etc_hosts( $hostname, $ip );

append_history_options_to_bashrc();
add_custom_bashrc_to_bash_profile();

# set env variable
# I am not entirely sure what we need this for or if it is even needed
# leaving for now but will need to be reevaluated in later on
local $ENV{'REMOTE_USER'} = 'root';

# ensure mysql is running and accessible before creating account
set_local_mysql_root_password();

# header message for '/etc/motd' placed here to ensure it is added before anything else
add_motd("\n\nVM Setup Script created the following test accounts:\n");

create_api_token();
create_primary_account();

update_tweak_settings();
disable_cphulkd();

# user has option to run upcp and check_cpanel_rpms
# this takes user input if necessary and executes these two processes if desired
handle_additional_options();

# install CloudLinux
# this logic should be moved to a subroutine and
# it will be revisited in TECH-407

# looks like this logic should work for now
# from a CL server
# # grep ^rpm_dist /var/cpanel/sysinfo.config
# rpm_dist=cloudlinux
if ( not $force and $sysinfo{'ostype'} eq "cloudlinux" ) {
    print_warn("CloudLinux already detected, no need to install CloudLinux\n");

    # No need to install CloudLinux. It's already installed
    $cltrue = 0;
}
if ($cltrue) {

    # Remove /var/cpanel/nocloudlinux touch file (if it exists)
    if ( -e ("/var/cpanel/nocloudlinux") ) {
        print_vms("Removing /var/cpanel/nocloudlinux touch file");
        unlink("/var/cpanel/nocloudlinux");
    }
    print_vms("Downloading cldeploy shell file");
    system_formatted("wget http://repo.cloudlinux.com/cloudlinux/sources/cln/cldeploy");
    print_vms("Executing cldeploy shell file (Note: this runs a upcp and can take time)");
    my $clDeploy = qx[ echo | sh cldeploy -k 42-2efe234f2ae327824e879a2bec87fc59 ; echo ];
    print_vms("Installing CageFS");
    system_formatted("echo | yum -y install cagefs");
    print_vms("Initializing CageFS");
    system_formatted("echo | cagefsctl --init");
    print_vms("Installing PHP Selector");
    system_formatted("echo | yum -y groupinstall alt-php");
    print_vms("Updating CageFS/LVE Manager");
    system_formatted("echo | yum -y update cagefs lvemanager");
}

# restart cpsrvd
restart_cpsrvd();

# exit cleanly
clean_exit();

exit;

##############  END OF MAIN ##########################
#
# list of subroutines for the script
#
# system_formatted() - takes a system call as an argument and uses open3() to make the syscall
# add_motd() - appends all arguments to '/etc/motd'
# get_sysinfo() - populates %sysinfo hash with data
# install_packages() - installs some useful yum packages
# create_api_token() - make API call to create an API token with the 'all' acl and add the token to '/etc/motd'
# create_primary_account() - create 'cptest' cPanel acct w/ email address, db, and dbuser - then add info to '/etc/motd'
# update_tweak_settings() - update tweak settings to allow remote domains and unregisteredomains
# disable_cphulkd() - stop and disable cphulkd
# restart_cpsrvd() - restarts cpsrvd
#
# print_help_and_exit() - ran if --help is passed - prints script usage/info and exits
# check_license() - perform a cPanel license check and die if it does not succeed
# handle_lock_file() - exit if lock file exists and --force is not passed, otherwise, create lock file
# handle_additional_options() - the script user has option to run a cPanel update and check_cpanel_rpms.  This executes these processes if the user desires
# clean_exit() - print some helpful output for the user before exiting
#
# setup_resolv_conf() - sets '/etc/resolv.conf' to use cPanel resolvers
# configure_99_hostname_cfg() - ensure '/etc/cloud/cloud.cfg.d/99_hostname.cfg' has proper contents
# configure_sysconfig_network() - ensure '/etc/sysconfig/network' has proper contents
# configure_mainip() - ensure '/var/cpanel/mainip' has proper contents
# configure_whostmgrft() - touch '/etc/.whostmgrft' to skip initial WHM setup
# configure_wwwacct_conf() - ensure '/etc/wwwacct.conf' has proper contents
# configure_etc_hosts() - ensure '/etc/hosts' has proper contents
# add_custom_bashrc_to_bash_profile() - append command to '/etc/.bash_profile' that changes source to https://ssp.cpanel.net/aliases/aliases.txt upon login
# create_vms_log_file() - creates the scripts log file
# append_vms_log() - appends a line (given as argument) to the scripts log file
#
#
# process_output() - processes the output of syscalls passed to system_formatted()
# print_formatted() - listens to read filehandle from syscall, and prints the output to STDOUT if verbose flag is used
# set_screen_perms() - ensure 'screen' binary has proper ownership/permissions
# ensure_working_rpmdb() - make sure that rpmdb is in working order before making yum syscall
# get_answer() - determines answer from user regarding additional options.  This subroutine takes a prompt string for STDOUT to the user and returns 'y' or 'n' depending on their answer
#
# print_vms() - color formatted output to make script output look better
# print_warn() - color formatted output to make script output look better
# print_info() - color formatted output to make script output look better
# print_question() - color formatted output to make script output look better
# print_command() - color formatted output to make script output look better
#
# _gen_pw() - returns a 25 char rand pw
# _stdin() - returns a string taken from STDIN
# _create_touch_file - take file name as argument and works similar to 'touch' command in bash
# _get_ip_and_natip() - called by get_sysinfo() to populate %sysinfo hash with system IP and NATIP
# _get_cpanel_tier - called by get_sysinfo() to populate %sysinfo hash with the cPanel tier
# _get_ostype_and_version() - called by get_sysinfo() to populate %sysinfo hash with the ostype and osversion
# _cpanel_getsysinfo() - called by get_sysinfo() to ensure that '/var/cpanel/sysinfo.config' is up to date
# _cat_file() - takes filename as arg and mimics bash cat command
# _check_license() - works much like system_formatted() but is only intended for the license check
# _check_for_failure() - looks at output of the license check and dies if it fails
# _process_whmapi_output() - called by process_output() and processes the output of whmapi1 calls to ensure the call completed successfully and to check for token output
# _process_uapi_output() - called by process_output() and processes the output of UAPI calls to ensure the call copmleted successfully
#
##############  BEGIN SUBROUTINES ####################

# called by process_output() and processes the output of whmapi1 calls to ensure the call completed successfully and to check for token output
# takes the output of a whmapi1 call as an argument (array)
# returns 0 if the call succeeded
# otherwise, it returns a string that contains the reason that the call failed
sub _process_whmapi_output {

    my @output = @_;
    my $key;
    my $value;
    my $reason;

    foreach my $line (@output) {
        if ( $line =~ /reason:/ ) {
            ( $key, $value ) = split /:/, $line;
            $reason = $value;
        }

        if ( $line =~ /result:/ ) {
            ( $key, $value ) = split /:/, $line;
            if ( $value == 0 ) {
                return "whmapi call failed:  $reason";
            }
        }

        if ( $line =~ /^\s*token:/ ) {
            ( $key, $value ) = split /:/, $line;
            add_motd( "Token name - all_access: " . $value . "\n" );
        }
    }

    return 0;
}

# called by process_output() and processes the output of UAPI calls to ensure the call copmleted successfully
# takes the output of a UAPI call as an argument (array)
# returns 0 if the call succeeds
# otherwise, it returns a string that contains the reason that the call failed
sub _process_uapi_output {

    my @output = @_;
    my $key;
    my $value;
    my $error;
    my $i = 0;

    foreach my $line (@output) {
        if ($i) {
            $error = $line;
            chomp($error);
            $i = 0;
        }

        if ( $line =~ /errors:/ ) {
            $i = 1;
        }

        if ( $line =~ /status:/ ) {
            ( $key, $value ) = split /:/, $line;
            if ( $value == 0 ) {
                return "uapi call failed:  $error";
            }
        }
    }

    return 0;
}

# deterines if the command is a whmapi1 or UAPI call and calls the appropriate subroutine to handle it
# takes two arguments
# arg[0] = the command that was called
# arg 2 = an array contianing the output of the call
# return 0 if the command was an API call and it failed
# otherwise, return 1
sub process_output {

    my @output = @_;
    my $cmd    = shift @output;
    my $result;

    if ( $cmd =~ /whmapi1/ ) {
        $result = _process_whmapi_output(@output);
        if ( $result ne '0' ) {
            print_command($cmd);
            print_warn($result);
            return 0;
        }
    }

    elsif ( $cmd =~ /uapi/ ) {
        $result = _process_uapi_output(@output);
        if ( $result ne '0' ) {
            print_command($cmd);
            print_warn($result);
            return 0;
        }
    }

    return 1;
}

# logs the output of the system call
# and prints the output to STDOUT if --verbose was passed
# takes 3 arguments
# argument 1 is the command that was passed to system_formatted()
# arguments 2 and 3 are file handles for where the system call was made
# return 0 if the system call was an API call that failed
# otherwise, return 1
sub print_formatted {

    my $cmd  = shift;
    my $r_fh = shift;
    my $e_fh = shift;

    my @output = $cmd;

    my $sel = IO::Select->new();    # notify us of reads on on our FHs
    $sel->add($r_fh);               # add the STDOUT FH
    $sel->add($e_fh);               # add the STDERR FH
    while ( my @ready = $sel->can_read ) {
        foreach my $fh (@ready) {
            my $line = <$fh>;
            if ( not defined $line ) {    # EOF for FH
                $sel->remove($fh);
                next;
            }

            else {
                push @output, $line;
            }

            append_vms_log($line);
            if ($verbose) {
                print $line;
            }
        }
    }

    return 0 if not process_output(@output);

    return 1;
}

# takes a command to make a system call with as an argument
# uses open3() to make the system call
# if the call is a call to yum, check the return value of the call and warn if yum fails
# return 0 if the command is an API call that fails
# otherwise, return 1
sub system_formatted {

    my $cmd = shift;
    my ( $pid, $r_fh, $e_fh );
    my $retval = 1;

    append_vms_log("\nCommand:  $cmd\n");
    if ($verbose) {
        print_command($cmd);
    }

    eval { $pid = open3( undef, $r_fh, $e_fh, $cmd ); };
    die "open3: $@\n" if $@;

    if ( not print_formatted( $cmd, $r_fh, $e_fh ) ) {
        $retval = 0;
    }

    # wait on child to finish before proceeding
    waitpid( $pid, 0 );

    # process output for yum
    if ( $cmd =~ /yum/ ) {
        my $exit_status = $? >> 8;
        if ( $exit_status && $exit_status != 0 ) {
            print_command($cmd);
            print_warn("Some yum modules may have failed to install, check log for detail");
        }
    }

    if ( not $retval ) {
        return 0;
    }

    else {
        return 1;
    }
}

# use String::Random to generate 25 digit password
# only use alphanumeric chars in pw
# return the pw
sub _genpw {

    my $gen = String::Random->new();
    return $gen->randregex('\w{25}');
}

# appends argument(s) to the end of /etc/motd
sub add_motd {
    open( my $etc_motd, ">>", '/etc/motd' ) or die $!;
    print $etc_motd "@_\n";
    close $etc_motd;

    return 1;
}

# get stdin from user and return it
sub _stdin {
    my $string = q{};

    chomp( $string = <> );
    return $string;
}

# print script usage information and exit
sub print_help_and_exit {
    print "Usage: perl vm_setup.pl [options]\n\n";
    print "Description: Performs a number of functions to prepare VMs (on service.cpanel.ninja) for immediate use. \n\n";
    print "Options: \n";
    print "-------------- \n";
    print "--force: Ignores previous run check\n";
    print "--fast: Skips all optional setup functions\n";
    print "--verbose: pretty self explanatory\n";
    print "--full: Passes yes to all optional setup functions\n";
    print "--installcl: Installs CloudLinux(can take a while and requires reboot)\n";
    print "Full list of things this does: \n";
    print "-------------- \n";
    print "- Installs common/useful packages\n";
    print "- Sets hostname\n";
    print "- Updates /var/cpanel/cpanel.config (Tweak Settings)\n";
    print "- Performs basic setup wizard\n";
    print "- Fixes /etc/hosts\n";
    print "- Fixes screen permissions\n";

    # print "- Runs cpkeyclt\n";
    print "- Creates test account (with email and database)\n";
    print "- Disables cphulkd\n";
    print "- Creates api key\n";
    print "- Updates motd\n";
    print "- Creates /root/.bash_profile with helpful aliases\n";
    print "- Runs upcp (optional)\n";
    print "- Runs check_cpanel_rpms --fix (optional)\n";
    print "- Downloads and runs cldeploy (Installs CloudLinux) --installcl (optional)\n";
    exit;
}

# script should only be run once without force
# exit if it has been ran and force not passed
# do nothing if force passed
# create lock file otherwise
sub handle_lock_file {
    if ( -e "/root/vmsetup.lock" ) {
        if ( !$force ) {
            print_warn("/root/vmsetup.lock exists. This script may have already been run. Use --force to bypass. Exiting...");
            exit;
        }
        else {
            print_info("/root/vmsetup.lock exists. --force passed. Ignoring...");
        }
    }
    else {
        # create lock file
        print_vms("creating lock file");
        _create_touch_file('/root/vmsetup.lock');
    }
    return 1;
}

# mimic bash touch command
sub _create_touch_file {
    my $fn = shift;

    open( my $touch_file, ">", $fn ) or die $!;
    close $touch_file;
    return 1;
}

# recreate resolv.conf using cPanel resolvers
sub setup_resolv_conf {
    print_vms("Adding resolvers");
    open( my $etc_resolv_conf, '>', '/etc/resolv.conf' )
      or die $!;
    print $etc_resolv_conf "search cpanel.net\n" . "nameserver 208.74.121.50\n" . "nameserver 208.74.125.59\n";
    close($etc_resolv_conf);
    return 1;
}

###### accepts a reference to a hash
## original declaration
##my %sysinfo = (
##    "ostype"    => undef,
##    "osversion" => undef,
##    "tier"      => undef,
##    "hostname"  => undef,
##    "ip"        => undef,
##    "natip"     => undef,
##    );
sub get_sysinfo {

    # populate '/var/cpanel/sysinfo.config'
    _cpanel_gensysinfo();

    my $ref = shift;

    # get value for keys 'ostype' and 'osversion'
    _get_ostype_and_version($ref);

    # get value for key 'tier'
    _get_cpanel_tier($ref);

    # concatanate it all together
    # get value for key 'hostname'
    $ref->{'hostname'} = $ref->{'ostype'} . $ref->{'osversion'} . '.' . $ref->{'tier'} . ".tld";

    # get value for keys 'ip' and 'natip'
    _get_ip_and_natip($ref);

    return 1;
}

###### accepts a reference to a hash
### original declaration
###my %sysinfo = (
###    "ostype"    => undef,
###    "osversion" => undef,
###    "tier"      => undef,
###    "hostname"  => undef,
###    "ip"        => undef,
###    "natip"     => undef,
###    );
sub _get_ip_and_natip {

    my $ref = shift;
    open( my $fh, '<', '/var/cpanel/cpnat' )
      or die $!;
    while (<$fh>) {
        if ( $_ =~ /^[1-9]/ ) {
            ( $ref->{'natip'}, $ref->{'ip'} ) = split / /, $_;
            chomp( $ref->{'ip'} );
        }
    }
    close $fh;

    return 1;
}

###### accepts a reference to a hash
### original declaration
###my %sysinfo = (
###    "ostype"    => undef,
###    "osversion" => undef,
###    "tier"      => undef,
###    "hostname"  => undef,
###    "ip"        => undef,
###    "natip"     => undef,
###    );
sub _get_cpanel_tier {

    my $ref = shift;
    my $key;
    open( my $fh, '<', '/etc/cpupdate.conf' )
      or die $!;
    while (<$fh>) {
        chomp($_);
        if ( $_ =~ /^CPANEL/ ) {
            ( $key, $ref->{'tier'} ) = split /=/, $_;
        }
    }
    close $fh;

    # replace . with - for hostname purposes
    $ref->{'tier'} =~ s/\./-/g;

    return 1;
}

###### accepts a reference to a hash
### original declaration
###my %sysinfo = (
###    "ostype"    => undef,
###    "osversion" => undef,
###    "tier"      => undef,
###    "hostname"  => undef,
###    "ip"        => undef,
###    "natip"     => undef,
###    );
sub _get_ostype_and_version {

    my $ref = shift;
    my $key;
    open( my $fh, '<', '/var/cpanel/sysinfo.config' )
      or die $!;
    while (<$fh>) {
        chomp($_);
        if ( $_ =~ /^rpm_dist_ver/ ) {
            ( $key, $ref->{'osversion'} ) = split /=/, $_;
        }
        elsif ( $_ =~ /^rpm_dist/ ) {
            ( $key, $ref->{'ostype'} ) = split /=/, $_;
        }
    }
    close $fh;
    return 1;
}

# we need a function to process the output from system_formatted in order to catch and throw exceptions
# in particular, the 'gensysinfo' will throw an exception that needs to be caught if the rpmdb is broken
sub _cpanel_gensysinfo {
    unlink '/var/cpanel/sysinfo.config';
    _create_touch_file('/var/cpanel/sysinfo.config');
    system_formatted("/usr/local/cpanel/scripts/gensysinfo");
    return 1;
}

# verifies the integrity of the rpmdb and install some useful yum packages
sub install_packages {

    # install useful yum packages
    # added perl-CDB_FILE to be installed through yum instead of cpanm
    print_vms("Installing utilities via yum [ mtr nmap telnet nc vim s3cmd bind-utils pwgen jwhois dev git pydf perl-CDB_File ] (this may take a couple minutes)");
    ensure_working_rpmdb();
    system_formatted('/usr/bin/yum -y install mtr nmap telnet nc vim s3cmd bind-utils pwgen jwhois dev git pydf perl-CDB_File');

    return 1;
}

# takes a hostname as an argument
sub configure_99_hostname_cfg {

    my $hn = shift;

    if ( -e '/etc/cloud/cloud.cfg.d/' and -d '/etc/cloud/cloud.cfg.d/' ) {

        # Now create a file in /etc/cloud/cloud.cfg.d/ called 99_hostname.cfg
        open( my $cloud_cfg, '>', '/etc/cloud/cloud.cfg.d/99_hostname.cfg' )
          or die $!;
        print $cloud_cfg "#cloud-config\n" . "hostname: $hn\n";
        close($cloud_cfg);
    }

    return 1;
}

# takes a hostname as an argument
sub configure_sysconfig_network {

    my $hn = shift;

    # set /etc/sysconfig/network
    print_vms("Updating /etc/sysconfig/network");
    open( my $etc_network, '>', '/etc/sysconfig/network' )
      or die $!;
    print $etc_network "NETWORKING=yes\n" . "NOZEROCONF=yes\n" . "HOSTNAME=$hn\n";
    close($etc_network);
    return 1;
}

# takes the systems natip as an argument
sub configure_mainip {

    my $nat = shift;

    print_vms("Updating /var/cpanel/mainip");
    open( my $fh, '>', '/var/cpanel/mainip' )
      or die $!;
    print $fh "$nat";
    close($fh);
    return 1;
}

# touches '/etc/.whostmgrft'
sub configure_whostmgrft {
    _create_touch_file('/etc/.whostmgrft');
    return 1;
}

# takes two arguments
# arg1 = hostname
# arg2 = natip
sub configure_wwwacct_conf {

    my $hn  = shift;
    my $nat = shift;

    # correct wwwacct.conf
    print_vms("Correcting /etc/wwwacct.conf");
    open( my $fh, '>', '/etc/wwwacct.conf' )
      or die $!;
    print $fh "HOST $hn\n";
    print $fh "ADDR $nat\n";
    print $fh "HOMEDIR /home\n";
    print $fh "ETHDEV eth0\n";
    print $fh "NS ns1.os.cpanel.vm\n";
    print $fh "NS2 ns2.os.cpanel.vm\n";
    print $fh "NS3\n";
    print $fh "NS4\n";
    print $fh "HOMEMATCH home\n";
    print $fh "NSTTL 86400\n";
    print $fh "TTL 14400\n";
    print $fh "DEFMOD paper_lantern\n";
    print $fh "SCRIPTALIAS y\n";
    print $fh "CONTACTPAGER\n";
    print $fh "CONTACTEMAIL\n";
    print $fh "LOGSTYLE combined\n";
    print $fh "DEFWEBMAILTHEME paper_lantern\n";
    close($fh);
    return 1;
}

# takes two arguments
# # arg1 = hostname
# # arg2 = ip
sub configure_etc_hosts {

    my $hn       = shift;
    my $local_ip = shift;

    # corrent /etc/hosts
    print_vms("Correcting /etc/hosts");
    open( my $fh, '>', '/etc/hosts' )
      or die $!;
    print $fh "127.0.0.1    localhost localhost.localdomain localhost4 localhost4.localdomain4\n";
    print $fh "::1          localhost localhost.localdomain localhost6 localhost6.localdomain6\n";
    print $fh "$local_ip    host $hostname\n";
    close($fh);
    return 1;
}

# ensure proper screen ownership/permissions
sub set_screen_perms {

    print_vms("Fixing screen perms");
    system_formatted('/bin/rpm --setugids screen && /bin/rpm --setperms screen');
    return 1;
}

# fixes common issues with rpmdb if they exist
sub ensure_working_rpmdb {
    system_formatted('/usr/local/cpanel/scripts/find_and_fix_rpm_issues');
    return 1;
}

# this creates an api token and adds it to '/etc/motd'
sub create_api_token {

    print_vms("Creating api token");
    system_formatted('/usr/local/cpanel/bin/whmapi1 api_token_create token_name=all_access acl-1=all');

    return 1;
}

# create the primary test account
# and add one-liners to motd for access
# if the whmapi1 call to create the primary account fails, and force is not passed
# then we print a warning and fail since the rest of UAPI calls depend on this call to pass and should fail as well
sub create_primary_account {

    my $rndpass;

    add_motd( "one-liner for access to WHM root access:\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=root service=whostmgrd | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2087$URL"), "\n" );

    # create test account
    print_vms("Creating test account - cptest");
    $rndpass = _genpw();
    if ( not system_formatted( "/usr/local/cpanel/bin/whmapi1 createacct username=cptest domain=cptest.tld password=" . $rndpass . " pkgname=my_package savepgk=1 maxpark=unlimited maxaddon=unlimited" ) and not $force ) {
        print_warn(q[Failed to create primary account (cptest.tld), skipping additional configurations for the account]);
        return 1;
    }

    add_motd( "one-liner for access to cPanel user: cptest\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=cptest service=cpaneld | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2083$URL"), "\n" );

    print_vms("Creating test email - testing\@cptest.tld");
    $rndpass = _genpw();
    system_formatted( "/usr/local/cpanel/bin/uapi --user=cptest Email add_pop email=testing\@cptest.tld password=" . $rndpass );
    add_motd( "one-liner for access to test email account: testing\@cptest.tld\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=testing@cptest.tld service=webmaild | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2096$URL"), "\n" );

    print_vms("Creating test database - cptest_testdb");
    system_formatted("/usr/local/cpanel/bin/uapi --user=cptest Mysql create_database name=cptest_testdb");

    print_vms("Creating test db user - cptest_testuser");
    $rndpass = _genpw();
    system_formatted( "/usr/local/cpanel/bin/uapi --user=cptest Mysql create_user name=cptest_testuser password=" . $rndpass );
    add_motd("mysql test user:  username:  cptest_testuser");
    add_motd("                  password:  $rndpass\n");

    print_vms("Adding all privs for cptest_testuser to cptest_testdb");
    system_formatted("/usr/local/cpanel/bin/uapi --user=cptest Mysql set_privileges_on_database user=cptest_testuser database=cptest_testdb privileges='ALL PRIVILEGES'");

    return 1;
}

# update tweak settings to allow creation of nonexistent addon domains
sub update_tweak_settings {

    print_vms("Updating tweak settings (cpanel.config)");
    system_formatted("/usr/local/cpanel/bin/whmapi1 set_tweaksetting key=allowremotedomains value=1");
    system_formatted("/usr/local/cpanel/bin/whmapi1 set_tweaksetting key=allowunregistereddomains value=1");
    return 1;
}

# append aliases directly into STDIN upon login
sub add_custom_bashrc_to_bash_profile {

    print_vms("Updating '/root/.bash_profile with help aliases");
    my $txt = q[ source /dev/stdin <<< "$(curl -s https://ssp.cpanel.net/aliases/aliases.txt)" ];
    open( my $fh, ">>", '/root/.bash_profile' ) or die $!;
    print $fh "$txt\n";
    close $fh;

    return 1;
}

# stop and disable cphulkd
sub disable_cphulkd {

    print_vms("Disabling cphulkd");
    system_formatted('/usr/local/cpanel/bin/whmapi1 disable_cphulk');

    return 1;
}

# user has option to run upcp and check_cpanel_rpms
# this takes user input if necessary and executes these two processes if desired
sub handle_additional_options {

    # upcp first
    my $answer = get_answer("would you like to run upcp now? [n]: ");
    if ( $answer eq "y" ) {
        print_vms("Running upcp");
        system_formatted('/scripts/upcp');
    }

    # check_cpanel_rpms second
    $answer = get_answer("would you like to run check_cpanel_rpms now? [n]: ");
    if ( $answer eq "y" ) {
        print_vms("Running check_cpanel_rpms");
        system_formatted('/scripts/check_cpanel_rpms --fix');
    }

    return 1;
}

# takes 1 argument - a string to print to obtain user input if necessary
# return y or n
sub get_answer {

    my $question = shift;

    if ($fast) {
        return 'n';
    }
    elsif ($full) {
        return 'y';
    }
    else {
        print_question($question);
        return _stdin();
    }

    # this should not be possible to reach
    return 1;
}

sub restart_cpsrvd {

    print_vms("Restarting cpsvrd");
    system_formatted("/usr/local/cpanel/scripts/restartsrv_cpsrvd");
    return 1;
}

# exit cleanly
sub clean_exit {

    print "\n";
    print_vms("Setup complete\n");

    # this is ugly and not helpful in regards to script output
    # _cat_file('/etc/motd');
    print "\n";
    if ($cltrue) {
        print_info("CloudLinux installed! A reboot is required!\n");
    }
    else {
        print_info("You should log out and back in.\n");
    }

    exit;
}

# takes filename as argument and prints output of file to STDOUT
sub _cat_file {

    my $fn = shift;
    open( my $fh, '<', $fn )
      or die $!;

    while (<$fh>) {
        print $_;
    }

    close $fh;

    return 1;
}

# perform a license check to ensure valid cPanel license
sub check_license {

    _check_license("/usr/local/cpanel/cpkeyclt");

    return 1;
}

# works just like system_formatted(), but I split this out specifically for the license check
sub _check_license {

    my $cmd = shift;
    my ( $pid, $r_fh );

    eval { $pid = open3( undef, $r_fh, '>&STDERR', $cmd ); };
    die "open3: $@\n" if $@;

    my $sel = IO::Select->new();    # notify us of reads on on our FHs
    $sel->add($r_fh);               # add the FH we are interested in
    while ( my @ready = $sel->can_read ) {
        foreach my $fh (@ready) {
            my $line = <$fh>;
            if ( not defined $line ) {    # EOF for FH
                $sel->remove($fh);
                next;
            }

            else {
                _check_for_failure($line);
            }
        }
    }

    # wait on child to finish before proceeding
    waitpid( $pid, 0 );

    return 1;
}

# takes a line of output as an argument
sub _check_for_failure {

    my $line = shift;

    # die if the license is not valid
    die("cPanel license is not currently valid.\n") if ( $line =~ /Update Failed!/ );

    return 1;
}

# no arguments needed since $VMS_LOG is a global var
# creates the file as a new file
sub create_vms_log_file {
    print_info("vm_setup logs to '$VMS_LOG'");

    unlink $VMS_LOG;
    _create_touch_file($VMS_LOG);
    return 1;
}

# append a line to the log file
# takes a line to append to the file as an argument
sub append_vms_log {
    my $line = shift;

    open( my $fh, ">>", $VMS_LOG ) or die $!;
    print $fh $line;
    close $fh;

    return 1;
}

sub print_vms {
    my $text = shift;
    print BOLD BRIGHT_BLUE ON_BLACK '[VMS] * ';
    print BOLD WHITE ON_BLACK "$text\n";
    return 1;
}

sub print_warn {
    my $text = shift;
    print BOLD RED ON_BLACK '[WARN] * ';
    print BOLD WHITE ON_BLACK "$text\n";
    return 1;
}

sub print_info {
    my $text = shift;
    print BOLD GREEN ON_BLACK '[INFO] * ';
    print BOLD WHITE ON_BLACK "$text\n";
    return 1;
}

sub print_question {
    my $text = shift;
    print BOLD CYAN ON_BLACK '[QUESTION] * ';
    print BOLD WHITE ON_BLACK "$text";
    return 1;
}

sub print_command {
    my $text = shift;
    print BOLD BRIGHT_YELLOW ON_BLACK '[COMMAND] * ';
    print BOLD WHITE ON_BLACK "$text\n";
    return 1;
}

# DOCUMENT SUBROUTINES BELOW THIS LINE

sub append_history_options_to_bashrc {

    open( my $fh, ">>", '/root/.bashrc' ) or die $!;
    print $fh "export HISTFILESIZE= \n";
    print $fh "export HISTSIZE=\n";
    close $fh;

    return 1;
}

sub set_local_mysql_root_password {

    print_vms("Setting new password for mysql");
    my $pw = _genpw();
    system_formatted("/usr/local/cpanel/bin/whmapi1 set_local_mysql_root_password password=$pw");

    return 1;
}
