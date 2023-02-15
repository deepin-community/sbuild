#
# Utility.pm: library for sbuild utility programs
# Copyright © 2006 Roger Leigh <rleigh@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
#
############################################################################

# Import default modules into main
package main;
use Sbuild qw($devnull);
use Sbuild::Sysconfig;

$ENV{'LC_ALL'} = "C.UTF-8";
$ENV{'SHELL'} = '/bin/sh';

# avoid intermixing of stdout and stderr
$| = 1;

package Sbuild::Utility;

use strict;
use warnings;

use Sbuild::Chroot;
use File::Temp qw(tempfile);
use Module::Load::Conditional qw(can_load); # Used to check for LWP::UserAgent
use Time::HiRes qw ( time ); # Needed for high resolution timers

sub get_dist ($);
sub setup ($$$);
sub cleanup ($);
sub shutdown ($);
sub get_unshare_cmd($);
sub get_tar_compress_option($);

my $current_session;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(setup cleanup shutdown check_url download get_unshare_cmd
    read_subuid_subgid CLONE_NEWNS CLONE_NEWUTS CLONE_NEWIPC CLONE_NEWUSER
    CLONE_NEWPID CLONE_NEWNET test_unshare get_tar_compress_options);

    $SIG{'INT'} = \&shutdown;
    $SIG{'TERM'} = \&shutdown;
    $SIG{'ALRM'} = \&shutdown;
    $SIG{'PIPE'} = \&shutdown;
}

sub get_dist ($) {
    my $dist = shift;

    $dist = "unstable" if ($dist eq "-u" || $dist eq "u");
    $dist = "testing" if ($dist eq "-t" || $dist eq "t");
    $dist = "stable" if ($dist eq "-s" || $dist eq "s");
    $dist = "oldstable" if ($dist eq "-o" || $dist eq "o");
    $dist = "experimental" if ($dist eq "-e" || $dist eq "e");

    return $dist;
}

sub setup ($$$) {
    my $namespace = shift;
    my $distribution = shift;
    my $conf = shift;

    $conf->set('VERBOSE', 1);
    $conf->set('NOLOG', 1);

    $distribution = get_dist($distribution);

    # TODO: Allow user to specify arch.
    # Use require instead of 'use' to avoid circular dependencies when
    # ChrootInfo modules happen to make use of this module
    my $chroot_info;
    if ($conf->get('CHROOT_MODE') eq 'schroot') {
	require Sbuild::ChrootInfoSchroot;
	$chroot_info = Sbuild::ChrootInfoSchroot->new($conf);
    } elsif ($conf->get('CHROOT_MODE') eq 'autopkgtest') {
	require Sbuild::ChrootInfoAutopkgtest;
	$chroot_info = Sbuild::ChrootInfoAutopkgtest->new($conf);
    } elsif ($conf->get('CHROOT_MODE') eq 'unshare') {
	require Sbuild::ChrootInfoUnshare;
	$chroot_info = Sbuild::ChrootInfoUnshare->new($conf);
    } else {
	require Sbuild::ChrootInfoSudo;
	$chroot_info = Sbuild::ChrootInfoSudo->new($conf);
    }

    my $session;

    $session = $chroot_info->create($namespace,
				    $distribution,
				    undef, # TODO: Add --chroot option
				    $conf->get('BUILD_ARCH'));

    if (!defined $session) {
	print STDERR "Error creating chroot info\n";
	return undef;
    }

    $session->set('Log Stream', \*STDOUT);

    my $chroot_defaults = $session->get('Defaults');
    $chroot_defaults->{'DIR'} = '/';
    $chroot_defaults->{'STREAMIN'} = $Sbuild::devnull;
    $chroot_defaults->{'STREAMOUT'} = \*STDOUT;
    $chroot_defaults->{'STREAMERR'} =\*STDOUT;

    $Sbuild::Utility::current_session = $session;

    if (!$session->begin_session()) {
	print STDERR "Error setting up $distribution chroot\n";
	return undef;
    }

    if (defined(&main::local_setup)) {
	return main::local_setup($session);
    }
    return $session;
}

sub cleanup ($) {
    my $conf = shift;

    if (defined(&main::local_cleanup)) {
	main::local_cleanup($Sbuild::Utility::current_session);
    }
    if (defined $Sbuild::Utility::current_session) {
	$Sbuild::Utility::current_session->end_session();
    }
}

sub shutdown ($) {
    cleanup($main::conf); # FIXME: don't use global
    exit 1;
}

# This method simply checks if a URL is valid.
sub check_url {
    my ($url) = @_;

    # If $url is a readable plain file on the local system, just return true.
    return 1 if (-f $url && -r $url);

    # Load LWP::UserAgent if possible, else return 0.
    if (! can_load( modules => { 'LWP::UserAgent' => undef, } )) {
	warn "install the libwww-perl package to support downloading dsc files";
	return 0;
    }

    # Setup the user agent.
    my $ua = LWP::UserAgent->new;

    # Determine if we need to specify any proxy settings.
    $ua->env_proxy;
    my $proxy = _get_proxy();
    if ($proxy) {
        $ua->proxy(['http', 'ftp'], $proxy);
    }

    # Dispatch a HEAD request, grab the response, and check the response for
    # success.
    my $res = $ua->head($url);
    return 1 if ($res->is_success);

    # URL wasn't valid.
    return 0;
}

# This method is used to retrieve a file, usually from a location on the
# Internet, but it can also be used for files in the local system.
# $url is location of file, $file is path to write $url into.
sub download {
    # The parameters will be any URL and a location to save the file to.
    my($url, $file) = @_;

    # If $url is a readable plain file on the local system, just return the
    # $url.
    return $url if (-f $url && -r $url);

    # Load LWP::UserAgent if possible, else return 0.
    if (! can_load( modules => { 'LWP::UserAgent' => undef, } )) {
	return 0;
    }

    # Filehandle we'll be writing to.
    my $fh;

    # If $file isn't defined, a temporary file will be used instead.
    ($fh, $file) = tempfile( UNLINK => 0 ) if (! $file);

    # Setup the user agent.
    my $ua = LWP::UserAgent->new;

    # Determine if we need to specify any proxy settings.
    $ua->env_proxy;
    my $proxy = _get_proxy();
    if ($proxy) {
        $ua->proxy(['http', 'ftp'], $proxy);
    }

    # Download the file.
    print "Downloading $url to $file.\n";
    my $expected_length; # Total size we expect of content
    my $bytes_received = 0; # Size of content as it is received
    my $percent; # The percentage downloaded
    my $tick; # Used for counting.
    my $start_time = time; # Record of the start time
    open($fh, '>', $file); # Destination file to download content to
    my $request = HTTP::Request->new(GET => $url);
    my $response = $ua->request($request,
        sub {
	    # Our own content callback subroutine
            my ($chunk, $response) = @_;

            $bytes_received += length($chunk);
            unless (defined $expected_length) {
                $expected_length = $response->content_length or undef;
            }
            if ($expected_length) {
                # Here we calculate the speed of the download to print out later
                my $speed;
                my $duration = time - $start_time;
                if ($bytes_received/$duration >= 1024 * 1024) {
                    $speed = sprintf("%.4g MB",
                        ($bytes_received/$duration) / (1024.0 * 1024)) . "/s";
                } elsif ($bytes_received/$duration >= 1024) {
                    $speed = sprintf("%.4g KB",
                        ($bytes_received/$duration) / 1024.0) . "/s";
                } else {
                    $speed = sprintf("%.4g B",
			($bytes_received/$duration)) . "/s";
                }
                # Calculate the percentage downloaded
                $percent = sprintf("%d",
                    100 * $bytes_received / $expected_length);
                $tick++; # Keep count
                # Here we print out a progress of the download. We start by
                # printing out the amount of data retrieved so far, and then
                # show a progress bar. After 50 ticks, the percentage is printed
                # and the speed of the download is printed. A new line is
                # started and the process repeats until the download is
                # complete.
                if (($tick == 250) or ($percent == 100)) {
		    if ($tick == 1) {
			# In case we reach 100% from tick 1.
			printf "%8s", sprintf("%d",
			    $bytes_received / 1024) . "KB";
			print " [.";
		    }
		    while ($tick != 250) {
			# In case we reach 100% before reaching 250 ticks
			print "." if ($tick % 5 == 0);
			$tick++;
		    }
                    print ".]";
                    printf "%5s", "$percent%";
                    printf "%12s", "$speed\n";
                    $tick = 0;
                } elsif ($tick == 1) {
                    printf "%8s", sprintf("%d",
                        $bytes_received / 1024) . "KB";
                    print " [.";
                } elsif ($tick % 5 == 0) {
                    print ".";
                }
            }
            # Write the contents of the download to our specified file
            if ($response->is_success) {
                print $fh $chunk; # Print content to file
            } else {
                # Print message upon failure during download
                print "\n" . $response->status_line . "\n";
                return 0;
            }
        }
    ); # End of our content callback subroutine
    close $fh; # Close the destination file

    # Print error message in case we couldn't get a response at all.
    if (!$response->is_success) {
        print $response->status_line . "\n";
        return 0;
    }

    # Print out amount of content received before returning the path of the
    # file.
    print "Download of $url successful.\n";
    print "Size of content downloaded: ";
    if ($bytes_received >= 1024 * 1024) {
	print sprintf("%.4g MB",
	    $bytes_received / (1024.0 * 1024)) . "\n";
    } elsif ($bytes_received >= 1024) {
	print sprintf("%.4g KB", $bytes_received / 1024.0) . "\n";
    } else {
	print sprintf("%.4g B", $bytes_received) . "\n";
    }

    return $file;
}

# This method is used to determine the proxy settings used on the local system.
# It will return the proxy URL if a proxy setting is found.
sub _get_proxy {
    my $proxy;

    # Attempt to acquire a proxy URL from apt-config.
    if (open(my $apt_config_output, '-|', '/usr/bin/apt-config dump')) {
        foreach my $tmp (<$apt_config_output>) {
            if ($tmp =~ m/^.*Acquire::http::Proxy\s+/) {
                $proxy = $tmp;
                chomp($proxy);
                # Trim the line to only the proxy URL
                $proxy =~ s/^.*Acquire::http::Proxy\s+"|";$//g;
                return $proxy;
            }
        }
        close $apt_config_output;
    }

    # Attempt to acquire a proxy URL from the user's or system's wgetrc
    # configuration.
    # First try the user's wgetrc
    if (open(my $wgetrc, '<', "$ENV{'HOME'}/.wgetrc")) {
        foreach my $tmp (<$wgetrc>) {
            if ($tmp =~ m/^[^#]*http_proxy/) {
                $proxy = $tmp;
                chomp($proxy);
                # Trim the line to only the proxy URL
                $proxy =~ s/^.*http_proxy\s*=\s*|\s+$//g;
                return $proxy;
            }
        }
        close($wgetrc);
    }
    # Now try the system's wgetrc
    if (open(my $wgetrc, '<', '/etc/wgetrc')) {
        foreach my $tmp (<$wgetrc>) {
            if ($tmp =~ m/^[^#]*http_proxy/) {
                $proxy = $tmp;
                chomp($proxy);
                # Trim the line to only the proxy URL
                $proxy =~ s/^.*http_proxy\s*=\s*|\s+$//g;
                return $proxy;
            }
        }
        close($wgetrc);
    }

    # At this point there should be no proxy settings. Return undefined.
    return 0;
}

# from sched.h
use constant {
    CLONE_NEWNS   => 0x20000,
    CLONE_NEWUTS  => 0x4000000,
    CLONE_NEWIPC  => 0x8000000,
    CLONE_NEWUSER => 0x10000000,
    CLONE_NEWPID  => 0x20000000,
    CLONE_NEWNET  => 0x40000000,
};

sub get_unshare_cmd($) {
    my $options = shift;

    my @idmap = @{$options->{'IDMAP'}};

    my $unshare_flags = CLONE_NEWUSER;

    if (defined($options->{'UNSHARE_FLAGS'})) {
	$unshare_flags |= $options->{'UNSHARE_FLAGS'};
    }

    my $uidmapcmd = "";
    my $gidmapcmd = "";
    foreach (@idmap) {
	my ($t, $hostid, $nsid, $range) = @{$_};
	if ($t ne "u" and $t ne "g" and $t ne "b") {
	    die "invalid idmap type: $t";
	}
	if ($t eq "u" or $t eq "b") {
	    $uidmapcmd .= " $hostid $nsid $range";
	}
	if ($t eq "g" or $t eq "b") {
	    $gidmapcmd .= " $hostid $nsid $range";
	}
    }
    my $idmapcmd = '';
    if ($uidmapcmd ne "") {
	$idmapcmd .= "0 == system \"newuidmap \$ppid $uidmapcmd\" or die \"newuidmap failed: \$!\";";
    }
    if ($gidmapcmd ne "") {
	$idmapcmd .= "0 == system \"newgidmap \$ppid $gidmapcmd\" or die \"newgidmap failed: \$!\";";
    }

    my $command = <<"EOF";
require 'syscall.ph';

# Create a pipe for the parent process to signal the child process that it is
# done with calling unshare() so that the child can go ahead setting up
# uid_map and gid_map.
pipe my \$rfh, my \$wfh;

# We have to do this dance with forking a process and then modifying the
# parent from the child because:
#  - new[ug]idmap can only be called on a process id after that process has
#    unshared the user namespace
#  - a process looses its capabilities if it performs an execve() with nonzero
#    user ids see the capabilities(7) man page for details.
#  - a process that unshared the user namespace by default does not have the
#    privileges to call new[ug]idmap on itself
#
# this also works the other way around (the child setting up a user namespace
# and being modified from the parent) but that way, the parent would have to
# stay around until the child exited (so a pid would be wasted). Additionally,
# that variant would require an additional pipe to let the parent signal the
# child that it is done with calling new[ug]idmap. The way it is done here,
# this signaling can instead be done by wait()-ing for the exit of the child.
my \$ppid = \$\$;
my \$cpid = fork() // die "fork() failed: \$!";
if (\$cpid == 0) {
	# child

	# Close the writing descriptor at our end of the pipe so that we see EOF
	# when parent closes its descriptor.
	close \$wfh;

	# Wait for the parent process to finish its unshare() call by waiting for
	# an EOF.
	0 == sysread \$rfh, my \$c, 1 or die "read() did not receive EOF";

	# The program's new[ug]idmap have to be used because they are setuid root.
	# These privileges are needed to map the ids from /etc/sub[ug]id to the
	# user namespace set up by the parent. Without these privileges, only the
	# id of the user itself can be mapped into the new namespace.
	#
	# Since new[ug]idmap is setuid root we also don't need to write "deny" to
	# /proc/\$\$/setgroups beforehand (this is otherwise required for
	# unprivileged processes trying to write to /proc/\$\$/gid_map since kernel
	# version 3.19 for security reasons) and therefore the parent process
	# keeps its ability to change its own group here.
	#
	# Since /proc/\$ppid/[ug]id_map can only be written to once, respectively,
	# instead of making multiple calls to new[ug]idmap, we assemble a command
	# line that makes one call each.
	$idmapcmd
	exit 0;
}

# parent

# After fork()-ing, the parent immediately calls unshare...
0 == syscall &SYS_unshare, $unshare_flags or die "unshare() failed: \$!";

# .. and then signals the child process that we are done with the unshare()
# call by sending an EOF.
close \$wfh;

# Wait for the child process to finish its setup by waiting for its exit.
\$cpid == waitpid \$cpid, 0 or die "waitpid() failed: \$!";
if (\$? != 0) {
	die "child had a non-zero exit status: \$?";
}

# Currently we are nobody (uid and gid are 65534). So we become root user and
# group instead.
#
# We are using direct syscalls instead of setting \$(, \$), \$< and \$> because
# then perl would do additional stuff which we don't need or want here, like
# checking /proc/sys/kernel/ngroups_max (which might not exist). It would also
# also call setgroups() in a way that makes the root user be part of the
# group unknown.
0 == syscall &SYS_setgid, 0 or die "setgid failed: \$!";
0 == syscall &SYS_setuid, 0 or die "setuid failed: \$!";
0 == syscall &SYS_setgroups, 0, 0 or die "setgroups failed: \$!";
EOF

    if ($options->{'FORK'}) {
	$command .= <<"EOF";
# When the pid namespace is also unshared, then processes expect a master pid
# to always be alive within the namespace. To achieve this, we fork() here
# instead of exec() to always have one dummy process running as pid 1 inside
# the namespace. This is also what the unshare tool does when used with the
# --fork option.
#
# Otherwise, without a pid 1, new processes cannot be forked anymore after pid
# 1 finished.
my \$cpid = fork() // die "fork() failed: \$!";
if (\$cpid != 0) {
    # The parent process will stay alive as pid 1 in this namespace until
    # the child finishes executing. This is important because pid 1 must
    # never die or otherwise nothing new can be forked.
    \$cpid == waitpid \$cpid, 0 or die "waitpid() failed: \$!";
    exit (\$? >> 8);
}
EOF
    }

    $command .= 'exec { $ARGV[0] } @ARGV or die "exec() failed: $!";';
    # remove code comments
    $command =~ s/^\s*#.*$//gm;
    # remove whitespace at beginning and end
    $command =~ s/^\s+//gm;
    $command =~ s/\s+$//gm;
    # remove linebreaks
    $command =~ s/\n//gm;
    return ('perl', '-e', $command);
}

sub read_subuid_subgid() {
    my $username = getpwuid $<;
    my ($subid, $num_subid, $fh, $n);
    my @result = ();

    if (! -e "/etc/subuid") {
	printf STDERR "/etc/subuid doesn't exist\n";
	return;
    }
    if (! -r "/etc/subuid") {
	printf STDERR "/etc/subuid is not readable\n";
	return;
    }

    open $fh, "<", "/etc/subuid" or die "cannot open /etc/subuid for reading: $!";
    while (my $line = <$fh>) {
	($n, $subid, $num_subid) = split(/:/, $line, 3);
	last if ($n eq $username);
    }
    close $fh;

    if ($n ne $username) {
	printf STDERR "No entry for $username in /etc/subuid";
	return;
    }

    push @result, ["u", 0, $subid, $num_subid];

    open $fh, "<", "/etc/subgid" or die "cannot open /etc/subgid for reading: $!";
    while (my $line = <$fh>) {
	($n, $subid, $num_subid) = split(/:/, $line, 3);
	last if ($n eq $username);
    }
    close $fh;

    if ($n ne $username) {
	printf STDERR "No entry for $username in /etc/subgid";
	return;
    }

    push @result, ["g", 0, $subid, $num_subid];

    return @result;
}

sub test_unshare() {
    # we spawn a new per process because if unshare succeeds, we would
    # otherwise have unshared the sbuild process itself which we don't want
    my $pid = fork();
    if ($pid == 0) {
	require "syscall.ph";
	my $ret = syscall &SYS_unshare, CLONE_NEWUSER;
	if (($ret >> 8) == 0) {
	    exit 0;
	} else {
	    exit 1;
	}
    }
    waitpid($pid, 0);
    if (($? >> 8) != 0) {
	printf STDERR "E: unshare failed: $!\n";
	my $procfile = '/proc/sys/kernel/unprivileged_userns_clone';
	open(my $fh, '<', $procfile) or die "failed to open $procfile";
	chomp(my $content = do { local $/; <$fh> });
	close($fh);
	if ($content ne "1") {
	    print STDERR "I: /proc/sys/kernel/unprivileged_userns_clone is set to $content\n";
	    print STDERR "I: try running: sudo sysctl -w kernel.unprivileged_userns_clone=1\n";
	    print STDERR "I: or permanently enable unprivileged usernamespaces by putting the setting into /etc/sysctl.d/\n";
	}
	return 0;
    }
    return 1;
}

# tar cannot figure out the decompression program when receiving data on
# standard input, thus we do it ourselves. This is copied from tar's
# src/suffix.c
sub get_tar_compress_options($) {
    my $filename = shift;
    if ($filename =~ /\.(gz|tgz|taz)$/) {
	return ('--gzip');
    } elsif ($filename =~ /\.(Z|taZ)$/) {
	return ('--compress');
    } elsif ($filename =~ /\.(bz2|tbz|tbz2|tz2)$/) {
	return ('--bzip2');
    } elsif ($filename =~ /\.lz$/) {
	return ('--lzip');
    } elsif ($filename =~ /\.(lzma|tlz)$/) {
	return ('--lzma');
    } elsif ($filename =~ /\.lzo$/) {
	return ('--lzop');
    } elsif ($filename =~ /\.lz4$/) {
	return ('--use-compress-program', 'lz4');
    } elsif ($filename =~ /\.(xz|txz)$/) {
	return ('--xz');
    } elsif ($filename =~ /\.zst$/) {
	return ('--zstd');
    }
    return ();
}

1;
