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

package Sbuild::AspcudResolver;

use strict;
use warnings;

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

    $self->log_subsection("Install $name build dependencies (aspcud-based resolver)");
    #install aspcud first:
    my (@aspcud_installed_packages, @aspcud_removed_packages);
    if (!$self->run_apt('-y', \@aspcud_installed_packages, \@aspcud_removed_packages, 'install', 'apt-cudf', 'aspcud')) {
	$self->log_warning('Could not install aspcud!');
	goto cleanup;
    }
    $self->set_installed(@aspcud_installed_packages);
    $self->set_removed(@aspcud_removed_packages);

    # Install the dummy package
    my (@instd, @rmvd);
    $self->log("Installing build dependencies\n");
    my @apt_args = ("-yf", \@instd, \@rmvd);
    push @apt_args, 'install', $dummy_pkg_name;

    push @apt_args, '--solver', 'aspcud',
	'-o', 'APT::Solver::Strict-Pinning=false',
	'-o', 'APT::Solver::aspcud::Preferences='.$self->get_conf('ASPCUD_CRITERIA');

    if (!$self->run_apt(@apt_args)) {
	$self->log("Package installation failed\n");
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

  cleanup:
    return $status;
}

sub purge_extra_packages {
    my $self = shift;
    my $name = shift;

    my $dummy_pkg_name = $self->get_sbuild_dummy_pkg_name($name);

    my $session = $self->get('Session');

    # we retrieve the list of installed Essential:yes packages because these
    # must not be removed
    my $pipe = $session->pipe_command({
	    COMMAND => [ 'dpkg-query', '--showformat', '${Essential} ${Package}\\n', '--show' ],
	    USER => $self->get_conf('BUILD_USER')
	});
    if (!$pipe) {
	$self->log_error("unable to execute dpkg-query\n");
	return 0;
    }
    my @essential;
    while (my $line = <$pipe>) {
	chomp $line;
	if ($line !~ /^yes ([a-zA-Z0-9][a-zA-Z0-9+.-]*)$/) {
	    next;
	}
	push @essential, "$1+";
    }
    close $pipe;
    if (scalar @essential == 0) {
	$self->log_error("no essential packages found \n");
	return 0;
    }
    # the /dev/null prevents acpcud from even looking at external repositories, so all it can do is remove stuff
    # it is also much faster that way
    my (@instd, @rmvd);
    $self->run_apt("-yf", \@instd, \@rmvd, 'autoremove',
	@essential, $self->get_sbuild_dummy_pkg_name('core') . '+', "$dummy_pkg_name+",
	'--solver', 'aspcud',
	'-o', 'APT::Solver::aspcud::Preferences=+removed',
	'-o', 'Dir::State::Lists=/dev/null',
	'--allow-remove-essential');
}

1;
