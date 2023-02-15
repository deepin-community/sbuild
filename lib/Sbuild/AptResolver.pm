# ResolverBase.pm: build library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
# Copyright © 2008      Simon McVittie <smcv@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

package Sbuild::AptResolver;

use strict;
use warnings;

use Sbuild qw(debug copy);
use Sbuild::Base;
use Sbuild::ResolverBase;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ResolverBase);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $session = shift;
    my $host = shift;

    my $self = $class->SUPER::new($conf, $session, $host);
    bless($self, $class);

    return $self;
}

sub install_deps {
    my $self = shift;
    my $name = shift;
    my @pkgs = @_;

    my $status = 0;
    my $session = $self->get('Session');
    my $dummy_pkg_name = $self->get_sbuild_dummy_pkg_name($name);

    # Call functions to setup an archive to install dummy package.
    $self->log_subsubsection("Setup apt archive");

    if (!$self->setup_apt_archive($dummy_pkg_name, @pkgs)) {
	$self->log_error("Setting up apt archive failed\n");
	return 0;
    }

    if (!$self->update_archive()) {
	$self->log_error("Updating apt archive failed\n");
	return 0;
    }

    $self->log_subsubsection("Install $name build dependencies (apt-based resolver)");

    # Install the dummy package
    my (@instd, @rmvd);
    $self->log("Installing build dependencies\n");
    my @apt_args = ("-yf", \@instd, \@rmvd, 'install', $dummy_pkg_name);

    if (!$self->run_apt(@apt_args)) {
	$self->log_error("Package installation failed\n");
	if (defined ($self->get('Session')->get('Session Purged')) &&
	    $self->get('Session')->get('Session Purged') == 1) {
	    $self->log("Not removing build depends: cloned chroot in use\n");
	} else {
	    $self->set_installed(@instd);
	    $self->set_removed(@rmvd);
	    goto package_cleanup;
	}
	return 0;
    }
    $self->set_installed(@instd);
    $self->set_removed(@rmvd);
    $status = 1;

  package_cleanup:
    if ($status == 0) {
	if (defined ($session->get('Session Purged')) &&
	    $session->get('Session Purged') == 1) {
	    $self->log("Not removing installed packages: cloned chroot in use\n");
	} else {
	    $self->uninstall_deps();
	}
    }

    return $status;
}

sub purge_extra_packages {
    my $self = shift;
    my $name = shift;

    my $dummy_pkg_name = $self->get_sbuild_dummy_pkg_name($name);

    my $session = $self->get('Session');

    # we partition the packages into those we want to mark as manual (all of
    # Essential:yes plus sbuild dummy packages) and those we want to mark as
    # auto
    #
    # We don't use the '*' glob of apt-mark because then we'd have all packages
    # apt knows about in the build log.
    my $pipe = $session->pipe_command({
	    COMMAND => [ 'dpkg-query', '--showformat', '${Essential} ${Package}\\n', '--show' ],
	    USER => $self->get_conf('BUILD_USER')
	});
    if (!$pipe) {
	$self->log_error("unable to execute dpkg-query\n");
	return 0;
    }
    my @essential;
    my @nonessential;
    while (my $line = <$pipe>) {
	chomp $line;
	if ($line !~ /^(yes|no) ([a-zA-Z0-9][a-zA-Z0-9+.-]*)$/) {
	    $self->log_error("dpkg-query output has unexpected format\n");
	    return 0;
	}
	# we only want to keep packages that are Essential:yes and the dummy
	# packages created by sbuild. Apt takes care to also keep their
	# transitive dependencies.
	if ($1 eq "yes" || $2 eq $dummy_pkg_name || $2 eq $self->get_sbuild_dummy_pkg_name('core')) {
	    push @essential, $2;
	} else {
	    push @nonessential, $2;
	}
    }
    close $pipe;
    if (scalar @essential == 0) {
	$self->log_error("no essential packages found \n");
	return 0;
    }
    if (scalar @nonessential == 0) {
	$self->log_error("no non-essential packages found \n");
	return 0;
    }

    if (!$session->run_command({ COMMAND => [ 'apt-mark', 'auto', @nonessential ], USER => 'root' })) {
	$self->log_error("unable to run apt-mark\n");
	return 0;
    }

    # We must mark all Essential:yes packages as manual because later on we
    # must run apt with --allow-remove-essential so that apt agrees to remove
    # itself and at that point we don't want to remove the Essential:yes
    # packages.
    if (!$session->run_command({ COMMAND => [ 'apt-mark', 'manual', @essential ], USER => 'root' })) {
	$self->log_error("unable to run apt-mark\n");
	return 0;
    }
    # apt currently suffers from bug #837066. It will never autoremove
    # priority:required packages, thus we use a temporary (famous last words)
    # hack here and feed apt a modified /var/lib/dpkg/status file with all
    # packages marked as Priority:extra. This is a hack because
    # /var/lib/dpkg/status should not be read by others than dpkg (we for
    # example do not take into account the journal that way).
    my $read_fh = $session->pipe_command({
	    COMMAND => [ 'sed', 's/^Priority: .*$/Priority: extra/', '/var/lib/dpkg/status' ],
	    USER => $self->get_conf('BUILD_USER')
	});
    if (!$read_fh) {
	$session->log_error("cannot run sed\n");
	return 0;
    }
    my $tmpfilename = $session->mktemp({ USER => $self->get_conf('BUILD_USER') });
    if (!$tmpfilename) {
	$session->log_error("cannot mktemp\n");
	return 0;
    }
    my $write_fh = $session->get_write_file_handle($tmpfilename);
    if (!$write_fh) {
	$session->log_error("cannot open $tmpfilename for writing\n");
	return 0;
    }
    while (read($read_fh, my $buffer, 1024)) {
	print $write_fh $buffer;
    }
    close $read_fh;
    close $write_fh;

    my (@instd, @rmvd);
    # apt considers itself as Essential:yes, that's why we need
    # --allow-remove-essential to remove it and that's why we must explicitly
    # specify to remove it.
    #
    # The /dev/null prevents apt from overriding the Priorities that we set in
    # our modified dpkg status file by the ones it finds in the package list
    # files
    $self->run_apt("-yf", \@instd, \@rmvd, 'autoremove',
	'apt',
	'-o', 'Dir::State::Lists=/dev/null',
	'-o', "Dir::State::Status=$tmpfilename",
	'--allow-remove-essential');

    $session->unlink($tmpfilename);
}

1;
