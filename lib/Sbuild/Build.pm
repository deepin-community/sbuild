#
# Build.pm: build library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2010 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Build;

use strict;
use warnings;

use English;
use POSIX;
use Errno qw(:POSIX);
use Fcntl;
use File::Temp qw(mkdtemp);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use FileHandle;
use File::Copy qw(); # copy is already exported from Sbuild, so don't export
		     # anything.
use Dpkg::Arch;
use Dpkg::Control;
use Dpkg::Index;
use Dpkg::Version;
use Dpkg::Deps qw(deps_concat deps_parse);
use Dpkg::Changelog::Debian;
use Scalar::Util 'refaddr';

use MIME::Lite;
use Term::ANSIColor;

use Sbuild qw($devnull binNMU_version copy isin debug send_mail
              dsc_files dsc_pkgver strftime_c);
use Sbuild::Base;
use Sbuild::ChrootInfoSchroot;
use Sbuild::ChrootInfoUnshare;
use Sbuild::ChrootInfoSudo;
use Sbuild::ChrootInfoAutopkgtest;
use Sbuild::ChrootRoot;
use Sbuild::Sysconfig qw($version $release_date);
use Sbuild::Sysconfig;
use Sbuild::Resolver qw(get_resolver);
use Sbuild::Exception;

use version;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

our $saved_stdout = undef;
our $saved_stderr = undef;

sub new {
    my $class = shift;
    my $dsc = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('ABORT', undef);
    $self->set('Job', $dsc);
    $self->set('Build Dir', '');
    $self->set('Max Lock Trys', 120);
    $self->set('Lock Interval', 5);
    $self->set('Pkg Status', 'pending');
    $self->set('Pkg Status Trigger', undef);
    $self->set('Pkg Start Time', 0);
    $self->set('Pkg End Time', 0);
    $self->set('Pkg Fail Stage', 'init');
    $self->set('Build Start Time', 0);
    $self->set('Build End Time', 0);
    $self->set('Install Start Time', 0);
    $self->set('Install End Time', 0);
    $self->set('This Time', 0);
    $self->set('This Space', 0);
    $self->set('Sub Task', 'initialisation');
    $self->set('Host', Sbuild::ChrootRoot->new($self->get('Config')));
    # Host execution defaults
    my $host_defaults = $self->get('Host')->get('Defaults');
    $host_defaults->{'USER'} = $self->get_conf('USERNAME');
    $host_defaults->{'DIR'} = $self->get_conf('HOME');
    $host_defaults->{'STREAMIN'} = $devnull;
    $host_defaults->{'ENV'}->{'LC_ALL'} = 'C.UTF-8';
    $host_defaults->{'ENV'}->{'SHELL'} = '/bin/sh';
    $host_defaults->{'ENV_FILTER'} = $self->get_conf('ENVIRONMENT_FILTER');
    # Note, this should never fail.  But, we should handle failure anyway.
    $self->get('Host')->begin_session();

    $self->set('Session', undef);
    $self->set('Dependency Resolver', undef);
    $self->set('Log File', undef);
    $self->set('Log Stream', undef);
    $self->set('Summary Stats', {});
    $self->set('dpkg-buildpackage pid', undef);
    $self->set('Dpkg Version', undef);

    # DSC, package and version information:
    $self->set_dsc($dsc);

    # If the job name contains an underscore then it is either the filename of
    # a dsc or a pkgname_version string. In both cases we can already extract
    # the version number. Otherwise it is a bare source package name and the
    # version will initially be unknown.
    if ($dsc =~ m/_/) {
	$self->set_version($dsc);
    } else {
	$self->set('Package', $dsc);
    }

    return $self;
}

sub request_abort {
    my $self = shift;
    my $reason = shift;

    $self->log_error("ABORT: $reason (requesting cleanup and shutdown)\n");
    $self->set('ABORT', $reason);

    # Send signal to dpkg-buildpackage immediately if it's running.
    if (defined $self->get('dpkg-buildpackage pid')) {
	# Handling ABORT in the loop reading from the stdout/stderr output of
	# dpkg-buildpackage is suboptimal because then the ABORT signal would
	# only be handled once the build process writes to stdout or stderr
	# which might not be immediately.
	my $pid = $self->get('dpkg-buildpackage pid');
	# Sending the pid negated to send to the whole process group.
	kill "TERM", -$pid;
    }
}

sub check_abort {
    my $self = shift;

    if ($self->get('ABORT')) {
	Sbuild::Exception::Build->throw(error => "Aborting build: " .
					$self->get('ABORT'),
					failstage => "abort");
    }
}

sub set_dsc {
    my $self = shift;
    my $dsc = shift;

    debug("Setting DSC: $dsc\n");

    $self->set('DSC', $dsc);
    $self->set('Source Dir', dirname($dsc));
    $self->set('DSC Base', basename($dsc));

    debug("DSC = " . $self->get('DSC') . "\n");
    debug("Source Dir = " . $self->get('Source Dir') . "\n");
    debug("DSC Base = " . $self->get('DSC Base') . "\n");
}

sub set_version {
    my $self = shift;
    my $pkgv = shift;

    debug("Setting package version: $pkgv\n");

    my ($pkg, $version);
    if (-f $pkgv && -r $pkgv) {
	($pkg, $version) = dsc_pkgver($pkgv);
    } else {
	($pkg, $version) = split /_/, $pkgv;
    }
    my $pver = Dpkg::Version->new($version, check => 1);
    return if (!defined($pkg) || !defined($version) || !defined($pver));
    my ($o_version);
    $o_version = $pver->version();

    # Original version (no binNMU or other addition)
    my $oversion = $version;
    # Original version with stripped epoch
    my $osversion = $o_version;
    $osversion .= '-' . $pver->revision() unless $pver->{'no_revision'};

    # Add binNMU to version if needed.
    if ($self->get_conf('BIN_NMU') || $self->get_conf('APPEND_TO_VERSION')
	|| defined $self->get_conf('BIN_NMU_CHANGELOG')) {
	if (defined $self->get_conf('BIN_NMU_CHANGELOG')) {
	    # extract the binary version from the custom changelog entry
	    open(CLOGFH, '<', \$self->get_conf('BIN_NMU_CHANGELOG'));
	    my $changes = Dpkg::Changelog::Debian->new();
	    $changes->parse(*CLOGFH, "descr");
	    my @data = $changes->get_range({count => 1});
	    $version = $data[0]->get_version();
	    close(CLOGFH);
	} else {
	    # compute the binary version from the original version and the
	    # requested binNMU and append-to-version parameters
	    $version = binNMU_version($version,
		$self->get_conf('BIN_NMU_VERSION'),
		$self->get_conf('APPEND_TO_VERSION'));
	}
    }

    my $bver = Dpkg::Version->new($version, check => 1);
    return if (!defined($bver));
    my ($b_epoch, $b_version, $b_revision);
    $b_epoch = $bver->epoch();
    $b_epoch = "" if $bver->{'no_epoch'};
    $b_version = $bver->version();
    $b_revision = $bver->revision();
    $b_revision = "" if $bver->{'no_revision'};

    # Version with binNMU or other additions and stripped epoch
    my $sversion = $b_version;
    $sversion .= '-' . $b_revision if $b_revision ne '';

    $self->set('Package', $pkg);
    $self->set('Version', $version);
    $self->set('Package_Version', "${pkg}_$version");
    $self->set('Package_OVersion', "${pkg}_$oversion");
    $self->set('Package_OSVersion', "${pkg}_$osversion");
    $self->set('Package_SVersion', "${pkg}_$sversion");
    $self->set('OVersion', $oversion);
    $self->set('OSVersion', $osversion);
    $self->set('SVersion', $sversion);
    $self->set('VersionEpoch', $b_epoch);
    $self->set('VersionUpstream', $b_version);
    $self->set('VersionDebian', $b_revision);
    $self->set('DSC File', "${pkg}_${osversion}.dsc");
    if (length $self->get_conf('DSC_DIR')) {
	$self->set('DSC Dir', $self->get_conf('DSC_DIR'));
    } else {
	$self->set('DSC Dir', "${pkg}-${b_version}");
    }

    debug("Package = " . $self->get('Package') . "\n");
    debug("Version = " . $self->get('Version') . "\n");
    debug("Package_Version = " . $self->get('Package_Version') . "\n");
    debug("Package_OVersion = " . $self->get('Package_OVersion') . "\n");
    debug("Package_OSVersion = " . $self->get('Package_OSVersion') . "\n");
    debug("Package_SVersion = " . $self->get('Package_SVersion') . "\n");
    debug("OVersion = " . $self->get('OVersion') . "\n");
    debug("OSVersion = " . $self->get('OSVersion') . "\n");
    debug("SVersion = " . $self->get('SVersion') . "\n");
    debug("VersionEpoch = " . $self->get('VersionEpoch') . "\n");
    debug("VersionUpstream = " . $self->get('VersionUpstream') . "\n");
    debug("VersionDebian = " . $self->get('VersionDebian') . "\n");
    debug("DSC File = " . $self->get('DSC File') . "\n");
    debug("DSC Dir = " . $self->get('DSC Dir') . "\n");
}

sub set_status {
    my $self = shift;
    my $status = shift;

    $self->set('Pkg Status', $status);
    if (defined($self->get('Pkg Status Trigger'))) {
	$self->get('Pkg Status Trigger')->($self, $status);
    }
}

sub get_status {
    my $self = shift;

    return $self->get('Pkg Status');
}

# This function is the main entry point into the package build.  It
# provides a top-level exception handler and does the initial setup
# including initiating logging and creating host chroot.  The nested
# run_ functions it calls are separate in order to permit running
# cleanup tasks in a strict order.
sub run {
    my $self = shift;

    eval {
	$self->check_abort();

	$self->set_status('building');

	$self->set('Pkg Start Time', time);
	$self->set('Pkg End Time', $self->get('Pkg Start Time'));

	# Acquire the architectures we're building for and on.
	$self->set('Host Arch', $self->get_conf('HOST_ARCH'));
	$self->set('Build Arch', $self->get_conf('BUILD_ARCH'));
	$self->set('Build Profiles', $self->get_conf('BUILD_PROFILES'));

	# Acquire the build type in the nomenclature used by the --build
	# argument of dpkg-buildpackage
	my $buildtype;
	if ($self->get_conf('BUILD_SOURCE')) {
	    if ($self->get_conf('BUILD_ARCH_ANY')) {
		if ($self->get_conf('BUILD_ARCH_ALL')) {
		    $buildtype = "full";
		} else {
		    $buildtype = "source,any";
		}
	    } else {
		if ($self->get_conf('BUILD_ARCH_ALL')) {
		    $buildtype = "source,all";
		} else {
		    $buildtype = "source";
		}
	    }
	} else {
	    if ($self->get_conf('BUILD_ARCH_ANY')) {
		if ($self->get_conf('BUILD_ARCH_ALL')) {
		    $buildtype = "binary";
		} else {
		    $buildtype = "any";
		}
	    } else {
		if ($self->get_conf('BUILD_ARCH_ALL')) {
		    $buildtype = "all";
		} else {
		    Sbuild::Exception::Build->throw(error => "Neither architecture specific nor architecture independent or source package specified to be built.",
			failstage => "init");
		}
	    }
	}
	$self->set('Build Type', $buildtype);

	my $dist = $self->get_conf('DISTRIBUTION');
	if (!defined($dist) || !$dist) {
	    Sbuild::Exception::Build->throw(error => "No distribution defined",
					    failstage => "init");
	}

	# TODO: Get package name from build object
	if (!$self->open_build_log()) {
	    Sbuild::Exception::Build->throw(error => "Failed to open build log",
					    failstage => "init");
	}

	# Set a chroot to run commands in host
	my $host = $self->get('Host');

	# Host execution defaults (set streams)
	my $host_defaults = $host->get('Defaults');
	$host_defaults->{'STREAMIN'} = $devnull;
	$host_defaults->{'STREAMOUT'} = $self->get('Log Stream');
	$host_defaults->{'STREAMERR'} = $self->get('Log Stream');

	$self->check_abort();
	$self->run_chroot();
    };

    debug("Error run(): $@") if $@;

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	if ($e->status) {
	    $self->set_status($e->status);
	} else {
	    $self->set_status("failed");
	}
	$self->set('Pkg Fail Stage', $e->failstage);
	$e->rethrow();
    }
}

# Pack up source if needed and then run the main chroot session.
# Close log during return/failure.
sub run_chroot {
    my $self = shift;

    eval {
	$self->check_abort();
	$self->run_chroot_session();
    };

    debug("Error run_chroot(): $@") if $@;

    # Log exception info and set status and fail stage prior to
    # closing build log.
    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$self->log_error("$e\n");
	$self->log_info($e->info."\n")
	    if ($e->info);
	if ($e->status) {
	    $self->set_status($e->status);
	} else {
	    $self->set_status("failed");
	}
	$self->set('Pkg Fail Stage', $e->failstage);
    }

    $self->close_build_log();

    if ($e) {
	$e->rethrow();
    }
}

# Create main chroot session and package resolver.  Creates a lock in
# the chroot to prevent concurrent chroot usage (only important for
# non-snapshot chroots).  Ends chroot session on return/failure.
sub run_chroot_session {
    my $self=shift;

    eval {
	$self->check_abort();
	my $chroot_info;
	if ($self->get_conf('CHROOT_MODE') eq 'schroot') {
	    $chroot_info = Sbuild::ChrootInfoSchroot->new($self->get('Config'));
	} elsif ($self->get_conf('CHROOT_MODE') eq 'autopkgtest') {
	    $chroot_info = Sbuild::ChrootInfoAutopkgtest->new($self->get('Config'));
	} elsif ($self->get_conf('CHROOT_MODE') eq 'unshare') {
	    $chroot_info = Sbuild::ChrootInfoUnshare->new($self->get('Config'));
	} else {
	    $chroot_info = Sbuild::ChrootInfoSudo->new($self->get('Config'));
	}

	my $host = $self->get('Host');

	my $session = $chroot_info->create('chroot',
					   $self->get_conf('DISTRIBUTION'),
					   $self->get_conf('CHROOT'),
					   $self->get_conf('BUILD_ARCH'));
        if (!defined $session) {
	    Sbuild::Exception::Build->throw(error => "Error creating chroot",
					    failstage => "create-session");
        }

	$self->check_abort();
	if (!$session->begin_session()) {
	    Sbuild::Exception::Build->throw(error => "Error creating chroot session: skipping " .
					    $self->get('Package'),
					    failstage => "create-session");
	}

	$self->set('Session', $session);

	$self->check_abort();
	my $chroot_arch =  $self->chroot_arch();
	if ($self->get_conf('BUILD_ARCH') ne $chroot_arch) {
	    Sbuild::Exception::Build->throw(
		error => "Requested build architecture (" .
		$self->get_conf('BUILD_ARCH') .
		") and chroot architecture (" . $chroot_arch .
		") do not match.  Skipping build.",
		info => "Please specify the correct architecture with --build, or use a chroot of the correct architecture",
		failstage => "create-session");
	}

	if (length $self->get_conf('BUILD_PATH')) {
	    my $build_path = $self->get_conf('BUILD_PATH');
	    $self->set('Build Dir', $build_path);
	    if (!($session->test_directory($build_path))) {
		if (!$session->mkdir($build_path, { PARENTS => 1})) {
		    Sbuild::Exception::Build->throw(
			error => "Buildpath: " . $build_path . " cannot be created",
			failstage => "create-session");
		}
	    } else {
		my $isempty = <<END;
if (opendir my \$dfh, "$build_path") {
    while (defined(my \$file=readdir \$dfh)) {
	next if \$file eq "." or \$file eq "..";
	closedir \$dfh;
	exit 1
    }
    closedir \$dfh;
    exit 0
}
exit 2
END
		$session->run_command({
			COMMAND => ['perl', '-e', $isempty],
			USER => 'root',
			DIR => '/'
		    });
		if ($? == 1) {
		    Sbuild::Exception::Build->throw(
			error => "Buildpath: " . $build_path . " is not empty",
			failstage => "create-session");
		}
		elsif ($? == 2) {
		    Sbuild::Exception::Build->throw(
			error => "Buildpath: " . $build_path . " cannot be read. Insufficient permissions?",
			failstage => "create-session");
		}
	    }
	} else {
		# we run mktemp within the chroot instead of using File::Temp::tempdir because the user
		# running sbuild might not have permissions creating a directory in /build. This happens
		# when the chroot was extracted in a different user namespace than the outer user
		$self->check_abort();
		my $tmpdir = $session->mktemp({
			TEMPLATE => "/build/" . $self->get('Package') . '-XXXXXX',
			DIRECTORY => 1});
		if (!$tmpdir) {
			$self->log_error("unable to mktemp\n");
			Sbuild::Exception::Build->throw(error => "unable to mktemp",
				failstage => "create-build-dir");
		}
		$self->check_abort();
		$self->set('Build Dir', $tmpdir);
	}

	# Copy in external solvers if we are cross-building
	if ($self->get('Host Arch') ne $self->get('Build Arch')) {
	    if (!$session->test_directory("/usr/lib/apt/solvers")) {
		if (!$session->mkdir("/usr/lib/apt/solvers", { PARENTS => 1})) {
		    Sbuild::Exception::Build->throw(
			error => "/usr/lib/apt/solvers cannot be created",
			failstage => "create-session");
		}
	    }
	    foreach my $solver ('apt', 'sbuild-cross-resolver') {
		if ($session->test_regular_file_readable("/usr/lib/apt/solvers/$solver")) {
		    next;
		}
		if (! -e "/usr/lib/apt/solvers/$solver") {
		    Sbuild::Exception::Build->throw(
			error => "/usr/lib/apt/solvers/$solver is missing",
			failstage => "create-session");
		}
		if (! $session->copy_to_chroot("/usr/lib/apt/solvers/$solver", "/usr/lib/apt/solvers/$solver")) {
		    Sbuild::Exception::Build->throw(
			error => "/usr/lib/apt/solvers/$solver cannot be copied",
			failstage => "create-session");
		}
		if (! $session->chmod("/usr/lib/apt/solvers/$solver", "0755")) {
		    Sbuild::Exception::Build->throw(
			error => "/usr/lib/apt/solvers/$solver cannot chmod",
			failstage => "create-session");
		}
	    }
	}

	# Run pre build external commands
	$self->check_abort();
	if(!$self->run_external_commands("pre-build-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute pre-build-commands",
		failstage => "run-pre-build-commands");
	}

	# Log colouring
	$self->build_log_colour('red', '^E: ');
	$self->build_log_colour('yellow', '^W: ');
	$self->build_log_colour('green', '^I: ');
	$self->build_log_colour('red', '^Status:');
	$self->build_log_colour('green', '^Status: successful$');
	$self->build_log_colour('yellow', '^Keeping session: ');
	$self->build_log_colour('red', '^Lintian:');
	$self->build_log_colour('yellow', '^Lintian: warn$');
	$self->build_log_colour('green', '^Lintian: pass$');
	$self->build_log_colour('green', '^Lintian: info$');
	$self->build_log_colour('red', '^Piuparts:');
	$self->build_log_colour('green', '^Piuparts: pass$');
	$self->build_log_colour('red', '^Autopkgtest:');
	$self->build_log_colour('yellow', '^Autopkgtest: no tests$');
	$self->build_log_colour('green', '^Autopkgtest: pass$');

	# Log filtering
	my $filter;
	$filter = $session->get('Location');
	$filter =~ s;^/;;;
	$self->build_log_filter($filter , 'CHROOT');

	# Need tempdir to be writable and readable by sbuild group.
	$self->check_abort();
	if (!$session->chown($self->get('Build Dir'), $self->get_conf('BUILD_USER'), 'sbuild')) {
	    Sbuild::Exception::Build->throw(error => "Failed to set sbuild group ownership on chroot build dir",
					    failstage => "create-build-dir");
	}
	$self->check_abort();
	if (!$session->chmod($self->get('Build Dir'), "ug=rwx,o=,a-s")) {
	    Sbuild::Exception::Build->throw(error => "Failed to set sbuild group ownership on chroot build dir",
					    failstage => "create-build-dir");
	}

	$self->check_abort();
	# Needed so chroot commands log to build log
	$session->set('Log Stream', $self->get('Log Stream'));
	$host->set('Log Stream', $self->get('Log Stream'));

	# Chroot execution defaults
	my $chroot_defaults = $session->get('Defaults');
	$chroot_defaults->{'DIR'} = $self->get('Build Dir');
	$chroot_defaults->{'STREAMIN'} = $devnull;
	$chroot_defaults->{'STREAMOUT'} = $self->get('Log Stream');
	$chroot_defaults->{'STREAMERR'} = $self->get('Log Stream');
	$chroot_defaults->{'ENV'}->{'LC_ALL'} = 'C.UTF-8';
	$chroot_defaults->{'ENV'}->{'SHELL'} = '/bin/sh';
	$chroot_defaults->{'ENV'}->{'HOME'} = '/sbuild-nonexistent';
	$chroot_defaults->{'ENV_FILTER'} = $self->get_conf('ENVIRONMENT_FILTER');

	my $resolver = get_resolver($self->get('Config'), $session, $host);
	$resolver->set('Log Stream', $self->get('Log Stream'));
	$resolver->set('Arch', $self->get_conf('ARCH'));
	$resolver->set('Host Arch', $self->get_conf('HOST_ARCH'));
	$resolver->set('Build Arch', $self->get_conf('BUILD_ARCH'));
	$resolver->set('Build Profiles', $self->get_conf('BUILD_PROFILES'));
	$resolver->set('Build Dir', $self->get('Build Dir'));
	$self->set('Dependency Resolver', $resolver);

	# Lock chroot so it won't be tampered with during the build.
	$self->check_abort();
	my $jobname;
	# the version might not yet be known if the user only passed a package
	# name without a version to sbuild
	if ($self->get('Package_SVersion')) {
	    $jobname = $self->get('Package_SVersion');
	} else {
	    $jobname = $self->get('Package');
	}
	if (!$session->lock_chroot($jobname, $$, $self->get_conf('USERNAME'))) {
	    Sbuild::Exception::Build->throw(error => "Error locking chroot session: skipping " .
					    $self->get('Package'),
					    failstage => "lock-session");
	}

	$self->check_abort();
	$self->run_chroot_session_locked();
    };

    debug("Error run_chroot_session(): $@") if $@;

    if ($self->get('Pkg Status') ne "successful") {
	if(!$self->run_external_commands("post-build-failed-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute post-build-commands",
		failstage => "run-post-build-failed-commands");
	}
    }

    # End chroot session
    my $session = $self->get('Session');
    if (defined $session) {
	    my $end_session =
		    ($self->get_conf('PURGE_SESSION') eq 'always' ||
		     ($self->get_conf('PURGE_SESSION') eq 'successful' &&
		      $self->get_status() eq 'successful')) ? 1 : 0;
	    if ($end_session) {
		    $session->end_session();
	    } else {
		    $self->log("Keeping session: " . $session->get('Session ID') . "\n");
	    }
	    $session = undef;
    }
    $self->set('Session', $session);

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$e->rethrow();
    }
}

# Run tasks in a *locked* chroot.  Update and upgrade packages.
# Unlocks chroot on return/failure.
sub run_chroot_session_locked {
    my $self = shift;

    eval {
	my $session = $self->get('Session');
	my $resolver = $self->get('Dependency Resolver');

	# Run specified chroot setup commands
	$self->check_abort();
	if(!$self->run_external_commands("chroot-setup-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute chroot-setup-commands",
		failstage => "run-chroot-setup-commands");
	}

	$self->check_abort();


	$self->check_abort();
	if (!$resolver->setup()) {
		Sbuild::Exception::Build->throw(error => "resolver setup failed",
						failstage => "resolver setup");
	}

	my $filter;
	$filter = $resolver->get('Dummy package path');
	$filter =~ s;^/;;;
	$self->build_log_filter($filter , 'RESOLVERDIR');

	$self->check_abort();
	$self->run_chroot_update();

	$self->check_abort();
	$self->run_fetch_install_packages();
    };

    debug("Error run_chroot_session_locked(): $@") if $@;

    my $session = $self->get('Session');
    my $resolver = $self->get('Dependency Resolver');

    $resolver->cleanup();
    # Unlock chroot now it's cleaned up and ready for other users.
    $session->unlock_chroot();

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$e->rethrow();
    }
}

sub run_chroot_update {
    my $self = shift;
    my $resolver = $self->get('Dependency Resolver');

    eval {
	if ($self->get_conf('APT_CLEAN') || $self->get_conf('APT_UPDATE') ||
	    $self->get_conf('APT_DISTUPGRADE') || $self->get_conf('APT_UPGRADE')) {
	    $self->log_subsection('Update chroot');
	}

	# Clean APT cache.
	$self->check_abort();
	if ($self->get_conf('APT_CLEAN')) {
	    if ($resolver->clean()) {
		# Since apt-clean was requested specifically, fail on
		# error when not in buildd mode.
		$self->log_error("apt-get clean failed\n");
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    Sbuild::Exception::Build->throw(error => "apt-get clean failed",
						    failstage => "apt-get-clean");
		}
	    }
	}

	# Update APT cache.
	$self->check_abort();
	if ($self->get_conf('APT_UPDATE')) {
	    if ($resolver->update()) {
		# Since apt-update was requested specifically, fail on
		# error when not in buildd mode.
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    Sbuild::Exception::Build->throw(error => "apt-get update failed",
						    failstage => "apt-get-update");
		}
	    }
	} else {
	    # If it was requested not to do an apt update, the build and host
	    # architecture must already be part of the chroot. If they are not
	    # and thus added during the sbuild run, issue a warning because
	    # then the package build dependencies will likely fail to be
	    # installable.
	    #
	    # The logic which checks which architectures are needed is in
	    # ResolverBase.pm, so we just check whether any architectures
	    # where added with 'dpkg --add-architecture' because if any were
	    # added an update is most likely needed.
	    if (keys %{$resolver->get('Added Foreign Arches')}) {
		$self->log_warning("Additional architectures were added but apt update was disabled. Build dependencies might not be satisfiable.\n");
	    }
	}

	# Upgrade using APT.
	$self->check_abort();
	if ($self->get_conf('APT_DISTUPGRADE')) {
	    if ($resolver->distupgrade()) {
		# Since apt-distupgrade was requested specifically, fail on
		# error when not in buildd mode.
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    Sbuild::Exception::Build->throw(error => "apt-get dist-upgrade failed",
						    failstage => "apt-get-dist-upgrade");
		}
	    }
	} elsif ($self->get_conf('APT_UPGRADE')) {
	    if ($resolver->upgrade()) {
		# Since apt-upgrade was requested specifically, fail on
		# error when not in buildd mode.
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    Sbuild::Exception::Build->throw(error => "apt-get upgrade failed",
						    failstage => "apt-get-upgrade");
		}
	    }
	}
    };

    debug("Error run_chroot_update(): $@") if $@;

    my $e = Exception::Class->caught('Sbuild::Exception::Build');
    if ($e) {
	$self->run_external_commands("chroot-update-failed-commands");
	$e->rethrow();
    }
}

# Fetch sources, run setup, fetch and install core and package build
# deps, then run build.  Cleans up build directory and uninstalls
# build depends on return/failure.
sub run_fetch_install_packages {
    my $self = shift;

    $self->check_abort();
    eval {
	my $session = $self->get('Session');
	my $resolver = $self->get('Dependency Resolver');

	$self->check_abort();
	if (!$self->fetch_source_files()) {
	    Sbuild::Exception::Build->throw(error => "Failed to fetch source files",
					    failstage => "fetch-src");
	}

	# Display message about chroot setup script option use being deprecated
	if ($self->get_conf('CHROOT_SETUP_SCRIPT')) {
	    my $msg = "setup-hook option is deprecated. It has been superseded by ";
	    $msg .= "the chroot-setup-commands feature. setup-hook script will be ";
	    $msg .= "run via chroot-setup-commands.\n";
	    $self->log_warning($msg);
	}

	$self->check_abort();
	$self->set('Install Start Time', time);
	$self->set('Install End Time', $self->get('Install Start Time'));
	my @coredeps = @{$self->get_conf('CORE_DEPENDS')};
	if ($self->get('Host Arch') ne $self->get('Build Arch')) {
	    my $crosscoredeps = $self->get_conf('CROSSBUILD_CORE_DEPENDS');
	    if (defined($crosscoredeps->{$self->get('Host Arch')})) {
	        push(@coredeps, @{$crosscoredeps->{$self->get('Host Arch')}});
	    } else {
		push(@coredeps, 'crossbuild-essential-' . $self->get('Host Arch') . ':native');
		# Also add the following to work around bug #815172
		push(@coredeps, 'libc-dev:' . $self->get('Host Arch'),
		    'libstdc++-dev:' . $self->get('Host Arch'));
            }
	}

	my @snapshot = ();
	@snapshot = ("gcc-snapshot") if ($self->get_conf('GCC_SNAPSHOT'));

	$resolver->add_dependencies('MAIN',
	    join(", ", $self->get('Build Depends') // (),
		       @{$self->get_conf('MANUAL_DEPENDS')}, @snapshot, @coredeps),
	    join(", ", $self->get('Build Depends Arch') // (),
		       @{$self->get_conf('MANUAL_DEPENDS_ARCH')}),
	    join(", ", $self->get('Build Depends Indep') // (),
		       @{$self->get_conf('MANUAL_DEPENDS_INDEP')}),
	    join(", ", $self->get('Build Conflicts') // (),
		       @{$self->get_conf('MANUAL_CONFLICTS')}),
	    join(", ", $self->get('Build Conflicts Arch') // (),
		       @{$self->get_conf('MANUAL_CONFLICTS_ARCH')}),
	    join(", ", $self->get('Build Conflicts Indep') // (),
		       @{$self->get_conf('MANUAL_CONFLICTS_INDEP')}));

	$self->log_subsection("Install package build dependencies");

	$self->check_abort();
	if (!$resolver->install_deps('main', 'MAIN')) {
	    Sbuild::Exception::Build->throw(error => "Package build dependencies not satisfied; skipping",
					    failstage => "install-deps");
	}
	$self->check_abort();
	if ($self->get_conf('PURGE_EXTRA_PACKAGES')) {
	    if (!$resolver->purge_extra_packages($self->get('Package'))) {
		Sbuild::Exception::Build->throw(error => "Chroot could not be cleaned of extra packages",
		    failstage => "install-deps");
	    }
	}
	$self->set('Install End Time', time);

	# the architecture check has to be done *after* build-essential is
	# installed because as part of the architecture check a perl script is
	# run inside the chroot which requires the Dpkg::Arch module which is
	# in libdpkg-perl which might not exist in the chroot but will get
	# installed by the build-essential package
	if(!$self->check_architectures()) {
	    Sbuild::Exception::Build->throw(error => "Architecture check failed",
					    failstage => "check-architecture");
	}

	$self->check_abort();
	my $dpkg_version = $resolver->dump_build_environment();
	$self->set('Dpkg Version',Dpkg::Version->new($dpkg_version));

	$self->check_abort();
	if ($self->build()) {
	    $self->set_status('successful');
	} else {
	    $self->set('Pkg Fail Stage', "build");
	    $self->set_status('failed');
	}

	# We run it here and not inside build() because otherwise, we cannot
	# set the overall status to failed due to lintian errors
	if ($self->get('Pkg Status') eq "successful") {
	    # Run lintian.
	    $self->check_abort();
	    my $ret = $self->run_lintian();
	    if (!$ret && $self->get_conf('LINTIAN_REQUIRE_SUCCESS')) {
		$self->set('Pkg Fail Stage', "post-build");
		$self->set_status("failed");
	    }
	}

	# Run specified chroot cleanup commands
	$self->check_abort();
	if (!$self->run_external_commands("chroot-cleanup-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute chroot-cleanup-commands",
		failstage => "run-chroot-cleanup-commands");
	}

	# piuparts and autopkgtest must be run while the chroot is still open
	# because they might need files that are not available on the host,
	# for example the .dsc which might have been downloaded
	if ($self->get('Pkg Status') eq "successful") {
	    $self->log_subsection("Post Build");

	    # Run piuparts.
	    $self->check_abort();
	    my $ret = $self->run_piuparts();
	    if (!$ret && $self->get_conf('PIUPARTS_REQUIRE_SUCCESS')) {
		$self->set('Pkg Fail Stage', "post-build");
		$self->set_status("failed");
	    }

	    # Run autopkgtest.
	    $self->check_abort();
	    $ret = $self->run_autopkgtest();
	    if (!$ret && $self->get_conf('AUTOPKGTEST_REQUIRE_SUCCESS')) {
		$self->set('Pkg Fail Stage', "post-build");
		$self->set_status("failed");
	    }

	    # Run post build external commands
	    $self->check_abort();
	    if(!$self->run_external_commands("post-build-commands")) {
		Sbuild::Exception::Build->throw(error => "Failed to execute post-build-commands",
		    failstage => "run-post-build-commands");
	    }

	}
    };

    # If 'This Time' is still zero, then build() raised an exception and thus
    # the end time was never set. Thus, setting it here.
    # If we would set 'This Time' here unconditionally, then it would also
    # possibly include the times to run piuparts and autopkgtest.
    if ($self->get('This Time') == 0) {
	$self->set('This Time', $self->get('Pkg End Time') - $self->get('Pkg Start Time'));
	$self->set('This Time', 0) if $self->get('This Time') < 0;
    }
    # Same for 'This Space' which we must set here before everything gets
    # cleaned up.
    if ($self->get('This Space') == 0) {
	# Since the build apparently failed, we pass an empty list of the
	# build artifacts
	$self->set('This Space', $self->check_space());
    }

    debug("Error run_fetch_install_packages(): $@") if $@;

    # I catch the exception here and trigger the hook, if needed. Normally I'd
    # do this at the end of the function, but I want the hook to fire before we
    # clean up the environment. I re-throw the exception at the end, as usual
    my $e = Exception::Class->caught('Sbuild::Exception::Build');
    if ($e) {
	if ($e->status) {
	    $self->set_status($e->status);
	} else {
	    $self->set_status("failed");
	}
	$self->set('Pkg Fail Stage', $e->failstage);
    }
    if (!$self->get('ABORT') && defined $self->get('Pkg Fail Stage')) {
	if ($self->get('Pkg Fail Stage') eq 'build' ) {
	    if(!$self->run_external_commands("build-failed-commands")) {
		Sbuild::Exception::Build->throw(error => "Failed to execute build-failed-commands",
		    failstage => "run-build-failed-commands");
	    }
	} elsif($self->get('Pkg Fail Stage') eq 'install-deps' ) {
            my $could_not_explain = undef;

	    if (defined $self->get_conf('BD_UNINSTALLABLE_EXPLAINER')
		&& $self->get_conf('BD_UNINSTALLABLE_EXPLAINER') ne ''
		&& $self->get_conf('BD_UNINSTALLABLE_EXPLAINER') ne 'none') {
		if (!$self->explain_bd_uninstallable()) {
                    $could_not_explain = 1;
		}
	    }

	    if(!$self->run_external_commands("build-deps-failed-commands")) {
		Sbuild::Exception::Build->throw(error => "Failed to execute build-deps-failed-commands",
		    failstage => "run-build-deps-failed-commands");
	    }

            if( $could_not_explain ) {
                Sbuild::Exception::Build->throw(error => "Failed to explain bd-uninstallable",
                                                failstage => "explain-bd-uninstallable");
            }
	}
    }

    $self->log_subsection("Cleanup");
    my $session = $self->get('Session');
    my $resolver = $self->get('Dependency Resolver');

    my $purge_build_directory =
	($self->get_conf('PURGE_BUILD_DIRECTORY') eq 'always' ||
	 ($self->get_conf('PURGE_BUILD_DIRECTORY') eq 'successful' &&
	  $self->get_status() eq 'successful')) ? 1 : 0;
    my $purge_build_deps =
	($self->get_conf('PURGE_BUILD_DEPS') eq 'always' ||
	 ($self->get_conf('PURGE_BUILD_DEPS') eq 'successful' &&
	  $self->get_status() eq 'successful')) ? 1 : 0;
    my $is_cloned_session = (defined ($session->get('Session Purged')) &&
			     $session->get('Session Purged') == 1) ? 1 : 0;

    if ($purge_build_directory) {
	# Purge package build directory
	$self->log("Purging " . $self->get('Build Dir') . "\n");
	if (!$self->get('Session')->unlink($self->get('Build Dir'), { RECURSIVE => 1 })) {
		$self->log_error("unable to remove build directory\n");
	}
    }

    # Purge non-cloned session
    if ($is_cloned_session) {
	$self->log("Not cleaning session: cloned chroot in use\n");
    } else {
	if ($purge_build_deps) {
	    # Removing dependencies
	    $resolver->uninstall_deps();
	} else {
	    $self->log("Not removing build depends: as requested\n");
	}
    }


    # re-throw the previously-caught exception
    if ($e) {
	$e->rethrow();
    }
}

sub copy_to_chroot {
    my $self = shift;
    my $source = shift;
    my $chrootdest = shift;

    my $session = $self->get('Session');

    $self->check_abort();
    if(!$session->copy_to_chroot($source, $chrootdest)) {
	$self->log_error("Failed to copy $source to $chrootdest\n");
	return 0;
    }

    if (!$session->chown($chrootdest, $self->get_conf('BUILD_USER'), 'sbuild')) {
	$self->log_error("Failed to set sbuild group ownership on $chrootdest\n");
	return 0;
    }
    if (!$session->chmod($chrootdest, "ug=rw,o=r,a-s")) {
	$self->log_error("Failed to set 0644 permissions on $chrootdest\n");
	return 0;
    }

    return 1;
}
sub fetch_source_files {
    my $self = shift;

    my $build_dir = $self->get('Build Dir');
    my $host_arch = $self->get('Host Arch');
    my $resolver = $self->get('Dependency Resolver');

    my ($dscarchs, $dscpkg, $dscver, $dsc);

    my $build_depends = "";
    my $build_depends_arch = "";
    my $build_depends_indep = "";
    my $build_conflicts = "";
    my $build_conflicts_arch = "";
    my $build_conflicts_indep = "";
    local( *F );

    $self->log_subsection("Fetch source files");

    $self->check_abort();
    if ($self->get('DSC Base') =~ m/\.dsc$/) {
	my $dir = $self->get('Source Dir');

	# Work with a .dsc file.
	my $file = $self->get('DSC');
	$dsc = $self->get('DSC File');
	if (! -f $file || ! -r $file) {
	    $self->log_error("Could not find $file\n");
	    return 0;
	}
	my @cwd_files = dsc_files($file);

	# Copy the local source files into the build directory.
	$self->log_subsubsection("Local sources");
	$self->log("$file exists in $dir; copying to chroot\n");
	if (! $self->copy_to_chroot("$file", "$build_dir/$dsc")) {
	    $self->log_error("Could not copy $file to $build_dir/$dsc\n");
	    return 0;
	}
	foreach (@cwd_files) {
	    if (! $self->copy_to_chroot("$dir/$_", "$build_dir/$_")) {
		$self->log_error("Could not copy $dir/$_ to $build_dir/$_\n");
		return 0;
	    }
	}
    } else {
	my $pkg = $self->get('DSC');
	my $ver;

	if ($pkg =~ m/_/) {
	    ($pkg, $ver) = split /_/, $pkg;
	}

	# Use apt to download the source files
	$self->log_subsubsection("Check APT");

        my $indextargets;
        {
            my $pipe = $self->get('Session')->pipe_command(
                {
                    COMMAND => [ 'apt-get', 'indextargets' ],
                    USER    => $self->get_conf('BUILD_USER'),
                }
            );
            if ( !$pipe ) {
                $self->log_error("Can't open pipe to apt-get: $!\n");
                return 0;
            }
            $indextargets =
              Dpkg::Index->new( get_key_func => sub { return $_[0]->{URI}; } );

            if ( !$indextargets->parse( $pipe, 'apt-get indextargets' ) ) {
                $self->log_error(
                    "Cannot parse output of apt-get indextargets: $!\n");
                return 0;
            }
            close($pipe);

            if ($?) {
                $self->log_error("apt-get indextargets exit status $?: $!\n");
                return 0;
            }
        }
        my $found_sources_entry  = 0;
        my $num_packages_entries = 0;
        my $entry_uri            = undef;
        my $entry_codename       = undef;
        my $entry_component      = undef;
        foreach my $key ( $indextargets->get_keys() ) {
            my $cdata      = $indextargets->get_by_key($key);
            my $createdby  = $cdata->{"Created-By"} // "";
            my $targetof   = $cdata->{"Target-Of"}  // "";
            my $identifier = $cdata->{"Identifier"} // "";
            if (    $createdby eq "Sources"
                and $identifier eq "Sources"
                and $targetof eq "deb-src" )
            {
                $found_sources_entry = 1;
            }
            if (    $createdby eq 'Packages'
                and $identifier eq 'Packages'
                and $targetof eq 'deb'
                and length $cdata->{"Repo-URI"} > 0
                and length $cdata->{"Codename"} > 0
                and length $cdata->{"Label"} > 0
                and length $cdata->{"Origin"} > 0
                and length $cdata->{"Suite"} > 0
                and $cdata->{"Repo-URI"} =~ /^file:\//
                and $cdata->{"Codename"} eq 'invalid-sbuild-codename'
                and $cdata->{'Label'} eq 'sbuild-build-depends-archive'
                and $cdata->{'Origin'} eq 'sbuild-build-depends-archive'
                and $cdata->{'Suite'} eq 'invalid-sbuild-suite' )
            {
                # do not count the sbuild dummy repository created by any
                # --extra-package options
                next;
            }
            if (    $createdby eq 'Packages'
                and $identifier eq 'Packages'
                and $targetof eq 'deb'
                and length $cdata->{"Repo-URI"} > 0
                and length $cdata->{"Codename"} > 0
                and length $cdata->{"Component"} > 0 )
            {
                $num_packages_entries += 1;
                $entry_uri       = $cdata->{"Repo-URI"};
                $entry_codename  = $cdata->{"Codename"};
                $entry_component = $cdata->{"Component"};
            }
        }
        if ( !$found_sources_entry ) {
            $self->log("There are no deb-src lines in your sources.list\n");
            if ( $num_packages_entries == 0 ) {
                $self->log("Cannot generate deb-src entry without deb entry\n");
            }
            elsif ( $num_packages_entries > 1 ) {
                $self->log( "Cannot generate deb-src entry "
                      . "with more than one deb entry\n" );
            }
            else {
                my $entry =
                  "deb-src $entry_uri $entry_codename $entry_component";
                $self->log(
                    "Automatically adding to EXTRA_REPOSITORIES: $entry\n");
                push @{ $self->get_conf('EXTRA_REPOSITORIES') }, $entry;
                $resolver->add_extra_repositories();
                $self->run_chroot_update();
            }
        }

	$self->log("Checking available source versions...\n");

	# We would like to call apt-cache with --only-source so that the
	# result only contains source packages with the given name but this
	# feature was only introduced in apt 1.1~exp10 so it is only available
	# in Debian Stretch and later
	my $pipe = $self->get('Dependency Resolver')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_CACHE'),
			  '-q', 'showsrc', $pkg],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0,
	      DIR => '/'});
	if (!$pipe) {
	    $self->log_error("Can't open pipe to ".$self->get_conf('APT_CACHE').": $!\n");
	    return 0;
	}

	my $key_func = sub {
	    return $_[0]->{Package} . '_' . $_[0]->{Version};
	};

	my $index = Dpkg::Index->new(get_key_func=>$key_func);

	if (!$index->parse($pipe, 'apt-cache showsrc')) {
	    $self->log_error("Cannot parse output of apt-cache showsrc: $!\n");
	    return 0;
	}

	close($pipe);

	if ($?) {
	    $self->log_error($self->get_conf('APT_CACHE') . " exit status $?: $!\n");
	    return 0;
	}

	my $highestversion;
	my $highestdsc;

	foreach my $key ($index->get_keys()) {
	    my $cdata = $index->get_by_key($key);
	    my $pkgname = $cdata->{"Package"};
	    if (not defined($pkgname)) {
		$self->log_warning("apt-cache output without Package field\n");
		next;
	    }
	    # Since we cannot run apt-cache with --only-source because that
	    # feature was only introduced with apt 1.1~exp10, the result can
	    # contain source packages that we didn't ask for (but which
	    # contain binary packages of the name we specified). Since we only
	    # are interested in source packages of the given name, we skip
	    # everything that is a different source package.
	    if ($pkg ne $pkgname) {
		next;
	    }
	    my $pkgversion = $cdata->{"Version"};
	    if (not defined($pkgversion)) {
		$self->log_warning("apt-cache output without Version field\n");
		next;
	    }
	    if (defined($ver) and $ver ne $pkgversion) {
		next;
	    }
	    my $checksums = Dpkg::Checksums->new();
	    $checksums->add_from_control($cdata, use_files_for_md5 => 1);
	    my @files = grep {/\.dsc$/} $checksums->get_files();
	    if (scalar @files != 1) {
		$self->log_warning("apt-cache output with more than one .dsc\n");
		next;
	    }
	    if (!defined $highestdsc) {
		$highestdsc = $files[0];
		$highestversion = $pkgversion;
	    } else {
		if (version_compare($highestversion, $pkgversion) < 0) {
		    $highestdsc = $files[0];
		    $highestversion = $pkgversion;
		}
	    }
	}

	if (!defined $highestdsc) {
	    $self->log_error($self->get_conf('APT_CACHE') .
		" returned no information about $pkg source\n");
	    $self->log_error("Are there any deb-src lines in your /etc/apt/sources.list?\n");
	    return 0;
	}

	$self->set_dsc($highestdsc);
	$dsc = $highestdsc;

	$self->log_subsubsection("Download source files with APT");

	my $pipe2 = $self->get('Dependency Resolver')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_GET'), '--only-source', '-q', '-d', 'source', "$pkg=$highestversion"],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0}) || return 0;

	while(<$pipe2>) {
	    $self->log($_);
	}
	close($pipe2);
	if ($?) {
	    $self->log_error($self->get_conf('APT_GET') . " for sources failed\n");
	    return 0;
	}
    }

    my $pipe = $self->get('Session')->get_read_file_handle("$build_dir/$dsc");
    if (!$pipe) {
	$self->log_error("unable to open pipe\n");
	return 0;
    }

    my $pdsc = Dpkg::Control->new(type => CTRL_PKG_SRC);
    $pdsc->set_options(allow_pgp => 1);
    if (!$pdsc->parse($pipe, "$build_dir/$dsc")) {
	$self->log_error("Error parsing $build_dir/$dsc\n");
	return 0;
    }

    close($pipe);

    $build_depends = $pdsc->{'Build-Depends'};
    $build_depends_arch = $pdsc->{'Build-Depends-Arch'};
    $build_depends_indep = $pdsc->{'Build-Depends-Indep'};
    $build_conflicts = $pdsc->{'Build-Conflicts'};
    $build_conflicts_arch = $pdsc->{'Build-Conflicts-Arch'};
    $build_conflicts_indep = $pdsc->{'Build-Conflicts-Indep'};
    $dscarchs = $pdsc->{'Architecture'};
    $dscpkg = $pdsc->{'Source'};
    $dscver = $pdsc->{'Version'};

    $self->set_version("${dscpkg}_${dscver}");

    $build_depends =~ s/\n\s+/ /g if defined $build_depends;
    $build_depends_arch =~ s/\n\s+/ /g if defined $build_depends_arch;
    $build_depends_indep =~ s/\n\s+/ /g if defined $build_depends_indep;
    $build_conflicts =~ s/\n\s+/ /g if defined $build_conflicts;
    $build_conflicts_arch =~ s/\n\s+/ /g if defined $build_conflicts_arch;
    $build_conflicts_indep =~ s/\n\s+/ /g if defined $build_conflicts_indep;

    $self->set('Build Depends', $build_depends);
    $self->set('Build Depends Arch', $build_depends_arch);
    $self->set('Build Depends Indep', $build_depends_indep);
    $self->set('Build Conflicts', $build_conflicts);
    $self->set('Build Conflicts Arch', $build_conflicts_arch);
    $self->set('Build Conflicts Indep', $build_conflicts_indep);

    $self->set('Dsc Architectures', $dscarchs);

    # we set up the following filters this late because the user might only
    # have specified a source package name to build without a version in which
    # case we only get to know the final build directory now
    my $filter;
    $filter = $self->get('Build Dir') . '/' . $self->get('DSC Dir');
    $filter =~ s;^/;;;
    $self->build_log_filter($filter, 'PKGBUILDDIR');
    $filter = $self->get('Build Dir');
    $filter =~ s;^/;;;
    $self->build_log_filter($filter, 'BUILDDIR');

    return 1;
}

sub check_architectures {
    my $self = shift;
    my $resolver = $self->get('Dependency Resolver');
    my $dscarchs = $self->get('Dsc Architectures');
    my $build_arch = $self->get('Build Arch');
    my $host_arch = $self->get('Host Arch');
    my $session = $self->get('Session');

    $self->log_subsection("Check architectures");
    # Check for cross-arch dependencies
    # parse $build_depends* for explicit :arch and add the foreign arches, as needed
    #
    # This check only looks at the immediate build dependencies. This could
    # fail in a future where a foreign architecture direct build dependency of
    # architecture X depends on another foreign architecture package of
    # architecture Y. Architecture Y would not be added through this check as
    # sbuild will not traverse the dependency graph. Doing so would be very
    # complicated as new architectures would have to be added to a dependency
    # solver like dose3 as the graph is traversed and new architectures are
    # found.
    sub get_explicit_arches
    {
        my $visited_deps = pop;
        my @deps = @_;

        my %set;
        for my $dep (@deps)
        {
            # Break any recursion in the deps data structure (is this overkill?)
            next if !defined $dep;
            my $id = ref($dep) ? refaddr($dep) : "str:$dep";
            next if $visited_deps->{$id};
            $visited_deps->{$id} = 1;

            if ( exists( $dep->{archqual} ) )
            {
                if ( $dep->{archqual} )
                {
                    $set{$dep->{archqual}} = 1;
                }
            }
            else
            {
                for my $key (get_explicit_arches($dep->get_deps,
                                                 $visited_deps)) {
                    $set{$key} = 1;
                }
            }
        }

        return keys %set;
    }

    # we don't need to look at build conflicts here because conflicting with a
    # package of an explicit architecture does not mean that we need to enable
    # that architecture in the chroot
    my $build_depends_concat =
      deps_concat( grep {defined $_} ($self->get('Build Depends'),
                                      $self->get('Build Depends Arch'),
                                      $self->get('Build Depends Indep')));
    my $merged_depends = deps_parse( $build_depends_concat,
		reduce_arch => 1,
		host_arch => $self->get('Host Arch'),
		build_arch => $self->get('Build Arch'),
		build_dep => 1,
		reduce_profiles => 1,
		build_profiles => [ split / /, $self->get('Build Profiles') ]);
    if( !defined $merged_depends ) {
        my $msg = "Error! deps_parse() couldn't parse the Build-Depends '$build_depends_concat'";
        $self->log_error("$msg\n");
        return 0;
    }

    my @explicit_arches = get_explicit_arches($merged_depends, {});
    my @foreign_arches = grep {$_ !~ /any|all|native/} @explicit_arches;
    my $added_any_new;
    for my $foreign_arch(@foreign_arches)
    {
        $resolver->add_foreign_architecture($foreign_arch);
        $added_any_new = 1;
    }

    my @keylist=keys %{$resolver->get('Initial Foreign Arches')};
    $self->log('Initial Foreign Architectures: ' . join ' ', @keylist, "\n")
      if @keylist;
    $self->log('Foreign Architectures in build-deps: '. join ' ', @foreign_arches, "\n\n")
      if @foreign_arches;

    $self->run_chroot_update() if $added_any_new;

    # At this point, all foreign architectures should have been added to dpkg.
    # Thus, we now examine, whether the packages passed via --extra-package
    # can even be considered by dpkg inside the chroot with respect to their
    # architecture.

    # Retrieve all foreign architectures from the chroot. We need to do this
    # step because the user might've added more foreign arches to the chroot
    # beforehand.
    my @all_foreign_arches = split /\s+/, $session->read_command({
	    COMMAND => ['dpkg', '--print-foreign-architectures'],
	    USER => $self->get_conf('USERNAME'),
	});
    # we use an anonymous subroutine so that the referenced variables are
    # automatically rebound to their current values
    my $check_deb_arch = sub {
	my $pkg = shift;
	# Investigate the Architecture field of the binary package
	my $arch = $self->get('Host')->read_command({
		COMMAND => ['dpkg-deb', '--field', Cwd::abs_path($pkg), 'Architecture'],
		USER => $self->get_conf('USERNAME')
	    });
	if (!defined $arch) {
	    $self->log_warning("Failed to run dpkg-deb on $pkg. Skipping...\n");
	    next;
	}
	chomp $arch;
	# Only packages that are Architecture:all, the native architecture or
	# one of the configured foreign architectures are allowed.
	if ($arch ne 'all' and $arch ne $build_arch
		and !isin($arch, @all_foreign_arches)) {
	    $self->log_warning("Extra package $pkg of architecture $arch cannot be installed in the chroot\n");
	}
    };
    for my $deb (@{$self->get_conf('EXTRA_PACKAGES')}) {
	if (-f $deb) {
	    &$check_deb_arch($deb);
	} elsif (-d $deb) {
	    opendir(D, $deb);
	    while (my $f = readdir(D)) {
		next if (! -f "$deb/$f");
		next if ("$deb/$f" !~ /\.deb$/);
		&$check_deb_arch("$deb/$f");
	    }
	    closedir(D);
	} else {
	    $self->log_warning("$deb is neither a regular file nor a directory. Skipping...\n");
	}
    }

    # Check package arch makes sense to build
    if (!$dscarchs) {
	$self->log_warning("dsc has no Architecture: field -- skipping arch check!\n");
    } elsif ($self->get_conf('BUILD_SOURCE')) {
	# If the source package is to be built, then we do not need to check
	# if any of the source package's architectures can be built given the
	# current host architecture because then no matter the Architectures
	# field, at least the source package will end up getting built.
    } else {
	my $valid_arch;
	for my $a (split(/\s+/, $dscarchs)) {
	    # Check architecture wildcard matching with dpkg inside the chroot
	    # to avoid situations in which dpkg outside the chroot doesn't
	    # know about a new architecture yet
	    my $command = <<"EOF";
		use strict;
		use warnings;
		use Dpkg::Arch;
		if (Dpkg::Arch::debarch_is('$host_arch', '$a')) {
		    exit 0;
		}
		exit 1;
EOF
	    $session->run_command(
		{ COMMAND => ['perl',
			'-e',
			$command],
		    USER => 'root',
		    PRIORITY => 0,
		    DIR => '/' });
	    if ($? == 0) {
		$valid_arch = 1;
		last;
	    }
	}
	if ($dscarchs ne "any" && !($valid_arch) &&
	    !($dscarchs =~ /\ball\b/ && $self->get_conf('BUILD_ARCH_ALL')) )  {
	    my $msg = "dsc: $host_arch not in arch list or does not match any arch wildcards: $dscarchs -- skipping";
	    $self->log_error("$msg\n");
	    Sbuild::Exception::Build->throw(error => $msg,
					    status => "skipped",
					    failstage => "arch-check");
	    return 0;
	}
    }

    $self->log("Arch check ok ($host_arch included in $dscarchs)\n");

    return 1;
}

# Subroutine that runs any command through the system (i.e. not through the
# chroot. It takes a string of a command with arguments to run along with
# arguments whether to save STDOUT and/or STDERR to the log stream
sub run_command {
    my $self = shift;
    my $command = shift;
    my $log_output = shift;
    my $log_error = shift;
    my $chroot = shift;

    # Used to determine if we are to log from commands
    my ($out, $err, $defaults);

    # Run the command and save the exit status
	if (!$chroot)
	{
	    $defaults = $self->get('Host')->{'Defaults'};
	    $out = $defaults->{'STREAMOUT'} if ($log_output);
	    $err = $defaults->{'STREAMERR'} if ($log_error);

	    my %args = (PRIORITY  => 0,
			STREAMOUT => $out,
			STREAMERR => $err);
	    if(ref $command) {
		$args{COMMAND} = \@{$command};
		$args{COMMAND_STR} = "@{$command}";
	    } else {
		$args{COMMAND} = [split('\s+', $command)];
		$args{COMMAND_STR} = $command;
	    }

	    $self->get('Host')->run_command( \%args );
	} else {
	    $defaults = $self->get('Session')->{'Defaults'};
	    $out = $defaults->{'STREAMOUT'} if ($log_output);
	    $err = $defaults->{'STREAMERR'} if ($log_error);

	    my %args = (USER => 'root',
			PRIORITY => 0,
			STREAMOUT => $out,
			STREAMERR => $err);
	    if(ref $command) {
		$args{COMMAND} = \@{$command};
		$args{COMMAND_STR} = "@{$command}";
	    } else {
		$args{COMMAND} = [split('\s+', $command)];
		$args{COMMAND_STR} = $command;
	    }

	    $self->get('Session')->run_command( \%args );
	}
    my $status = $?;

    # Check if the command failed
    if ($status != 0) {
	return 0;
    }
    return 1;
}

# Subroutine that processes external commands to be run during various stages of
# an sbuild run. We also ask if we want to log any output from the commands
sub run_external_commands {
    my $self = shift;
    my $stage = shift;

    my $log_output = $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT');
    my $log_error  = $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR');

    # Return success now unless there are commands to run
    return 1 unless (${$self->get_conf('EXTERNAL_COMMANDS')}{$stage});

    # Determine which set of commands to run based on the parameter $stage
    my @commands = @{${$self->get_conf('EXTERNAL_COMMANDS')}{$stage}};
    return 1 if !(@commands);

    # Create appropriate log message and determine if the commands are to be
    # run inside the chroot or not, and as root or not.
    my $chroot = 0;
    if ($stage eq "pre-build-commands") {
	$self->log_subsection("Pre Build Commands");
    } elsif ($stage eq "chroot-setup-commands") {
	$self->log_subsection("Chroot Setup Commands");
	$chroot = 1;
    } elsif ($stage eq "chroot-update-failed-commands") {
	$self->log_subsection("Chroot-update Install Failed Commands");
	$chroot = 1;
    } elsif ($stage eq "build-deps-failed-commands") {
	$self->log_subsection("Build-Deps Install Failed Commands");
	$chroot = 1;
    } elsif ($stage eq "build-failed-commands") {
	$self->log_subsection("Generic Build Failed Commands");
	$chroot = 1;
    } elsif ($stage eq "starting-build-commands") {
	$self->log_subsection("Starting Timed Build Commands");
	$chroot = 1;
    } elsif ($stage eq "finished-build-commands") {
	$self->log_subsection("Finished Timed Build Commands");
	$chroot = 1;
    } elsif ($stage eq "chroot-cleanup-commands") {
	$self->log_subsection("Chroot Cleanup Commands");
	$chroot = 1;
    } elsif ($stage eq "post-build-commands") {
	$self->log_subsection("Post Build Commands");
    } elsif ($stage eq "post-build-failed-commands") {
	$self->log_subsection("Post Build Failed Commands");
    }

    # Run each command, substituting the various percent escapes (like
    # %SBUILD_DSC) from the commands to run with the appropriate subsitutions.
    my $hostarch = $self->get('Host Arch');
    my $buildarch = $self->get('Build Arch');
    my $build_dir = $self->get('Build Dir');
    my $shell_cmd = "bash -i </dev/tty >/dev/tty 2>/dev/tty";
    my %percent = (
	"%" => "%",
	"a" => $hostarch, "SBUILD_HOST_ARCH" => $hostarch,
	                  "SBUILD_BUILD_ARCH" => $buildarch,
	"b" => $build_dir, "SBUILD_BUILD_DIR" => $build_dir,
	"s" => $shell_cmd, "SBUILD_SHELL" => $shell_cmd,
    );
    if ($self->get('Changes File')) {
	my $changes = $self->get('Changes File');
	$percent{c} = $changes;
	$percent{SBUILD_CHANGES} = $changes;
    }
    # In case set_version has not been run yet, we do not know the dsc file or
    # directory yet. This can happen if the user only specified a source
    # package name without a version on the command line.
    if ($self->get('DSC Dir')) {
	my $dsc = $self->get('DSC');
	$percent{d} = $dsc;
	$percent{SBUILD_DSC} = $dsc;
	my $pkgbuild_dir = $build_dir . '/' . $self->get('DSC Dir');
	$percent{p} = $pkgbuild_dir;
	$percent{SBUILD_PKGBUILD_DIR} = $pkgbuild_dir;
    }
    if ($chroot == 0) {
	my $chroot_dir = $self->get('Session')->get('Location');
	$percent{r} = $chroot_dir;
	$percent{SBUILD_CHROOT_DIR} = $chroot_dir;
	# the %SBUILD_CHROOT_EXEC escape is only defined when the command is
	# to be run outside the chroot
	my $exec_string = $self->get('Session')->get_internal_exec_string();
	$percent{e} = $exec_string;
	$percent{SBUILD_CHROOT_EXEC} = $exec_string;
    }
    # Our escapes pattern, with longer escapes first, then sorted lexically.
    my $keyword_pat = join("|",
	sort {length $b <=> length $a || $a cmp $b} keys %percent);
    my $returnval = 1;
    foreach my $command (@commands) {

	my $substitute = sub {
	    foreach(@_) {
		if (/\%SBUILD_CHROOT_DIR/ || /\%r/) {
		    $self->log_warning("The %SBUILD_CHROOT_DIR and %r percentage escapes are deprecated and should not be used anymore. Please use %SBUILD_CHROOT_EXEC or %e instead.");
		}
		s{
		     # Match a percent followed by a valid keyword
		     \%($keyword_pat)
	     }{
		 # Substitute with the appropriate value only if it's defined
		 $percent{$1} || $&
	     }msxge;
	    }
	};

	my $command_str;
	if( ref $command ) {
	    $substitute->(@{$command});
	    $command_str = join(" ", @{$command});
	} else {
	    $substitute->($command);
	    $command_str = $command;
	}

	$self->log_subsubsection("$command_str");

	$returnval = $self->run_command($command, $log_output, $log_error, $chroot);
	$self->log("\n");
	if (!$returnval) {
	    $self->log_error("Command '$command_str' failed to run.\n");
	    # do not run any other commands of this type after the first
	    # failure
	    last;
	} else {
	    $self->log_info("Finished running '$command_str'.\n");
	}
    }
    $self->log("\nFinished processing commands.\n");
    $self->log_sep();
    return $returnval;
}

sub run_lintian {
    my $self = shift;
    my $session = $self->get('Session');

    return 1 unless ($self->get_conf('RUN_LINTIAN'));
    $self->set('Lintian Reason', 'error');

    if (!defined($session)) {
	$self->log_error("Session is undef. Cannot run lintian.\n");
	return 0;
    }

    $self->log_subsubsection("lintian");

    my $build_dir = $self->get('Build Dir');
    my $resolver = $self->get('Dependency Resolver');
    my $lintian = $self->get_conf('LINTIAN');
    my $changes = $self->get_changes();
    if (!defined($changes)) {
	$self->log_error(".changes is undef. Cannot run lintian.\n");
	return 0;
    }

    my @lintian_command = ($lintian);
    push @lintian_command, @{$self->get_conf('LINTIAN_OPTIONS')} if
        ($self->get_conf('LINTIAN_OPTIONS'));
    push @lintian_command, $changes;

    # If the source package was not instructed to be built, then it will not
    # be part of the .changes file and thus, the .dsc has to be passed to
    # lintian in addition to the .changes file.
    if (!$self->get_conf('BUILD_SOURCE')) {
	my $dsc = $self->get('DSC File');
	push @lintian_command, $dsc;
    }

    $resolver->add_dependencies('LINTIAN', 'lintian:native', "", "", "", "", "");
    return 1 unless $resolver->install_deps('lintian', 'LINTIAN');

    $self->log("Running lintian...\n");

    # we are not using read_command() because we also need the output for
    # non-zero exit codes
    my $pipe = $session->pipe_command(
        { COMMAND => \@lintian_command,
          PRIORITY => 0,
          DIR => $self->get('Build Dir'),
	  PIPE => "in"
        });
    if (!$pipe) {
        $self->log_error("Failed to exec Lintian: $!\n");
	return 0;
    }
    my $lintian_output = "";
    while (my $line = <$pipe>) {
	$self->log($line);
	$lintian_output .= $line;
    }
    close $pipe;

    $self->log("\n");
    if ($?) {
	my $status = $? >> 8;
        my $why = "unknown reason";
	$self->set('Lintian Reason', 'fail') if ($status == 1);
        $why = "runtime error" if ($status == 2);
        $why = "policy violation" if ($status == 1);
        $why = "received signal " . $? & 127 if ($? & 127);
        $self->log_error("Lintian run failed ($why)\n");

        return 0;
    } else {
	$self->set('Lintian Reason', 'pass');
	if ($lintian_output =~ m/^I: /m) {
	    $self->set('Lintian Reason', 'info');
	}
	if ($lintian_output =~ m/^W: /m) {
	    $self->set('Lintian Reason', 'warn');
	}
    }

    $self->log_info("Lintian run was successful.\n");
    return 1;
}

sub run_piuparts {
    my $self = shift;

    return 1 unless ($self->get_conf('RUN_PIUPARTS'));
    $self->set('Piuparts Reason', 'fail');

    $self->log_subsubsection("piuparts");

    my $piuparts = $self->get_conf('PIUPARTS');
    my @piuparts_command;
    # The default value is the empty array.
    # If the value is the default (empty array) prefix with 'sudo --'
    # If the value is a non-empty array, prefix with its values except if the
    # first value is an empty string in which case, prefix with nothing
    # If the value is not an array, prefix with that scalar except if the
    # scalar is the empty string in which case, prefix with nothing
    if (ref($self->get_conf('PIUPARTS_ROOT_ARGS')) eq "ARRAY") {
	if (scalar(@{$self->get_conf('PIUPARTS_ROOT_ARGS')})) {
	    if (@{$self->get_conf('PIUPARTS_ROOT_ARGS')}[0] ne '') {
		push @piuparts_command, @{$self->get_conf('PIUPARTS_ROOT_ARGS')};
	    }
	} else {
	    push @piuparts_command, 'sudo', '--';
	}
    } else {
	if ($self->get_conf('PIUPARTS_ROOT_ARGS') ne '') {
	    push @piuparts_command, $self->get_conf('PIUPARTS_ROOT_ARGS');
	}
    }
    push @piuparts_command, $piuparts;
    push @piuparts_command, @{$self->get_conf('PIUPARTS_OPTIONS')} if
        ($self->get_conf('PIUPARTS_OPTIONS'));
    push @piuparts_command, $self->get('Changes File');
    $self->get('Host')->run_command(
        { COMMAND => \@piuparts_command,
          PRIORITY => 0,
        });
    my $status = $? >> 8;

    # We must check for Ctrl+C (and other aborting signals) directly after
    # running the command so that we do not mark the piuparts run as successful
    # (the exit status will be zero)
    $self->check_abort();

    $self->log("\n");

    if ($status == 0) {
	$self->set('Piuparts Reason', 'pass');
    } else {
        $self->log_error("Piuparts run failed.\n");
        return 0;
    }

    $self->log_info("Piuparts run was successful.\n");
    return 1;
}

sub run_autopkgtest {
    my $self = shift;

    return 1 unless ($self->get_conf('RUN_AUTOPKGTEST'));

    $self->set('Autopkgtest Reason', 'fail');

    $self->log_subsubsection("autopkgtest");

    my $session = $self->get('Session');

    # sbuild used to check whether debian/tests/control exists and would not
    # run autopkgtest at all if it didn't. This is wrong behaviour because
    # even packages without a debian/tests/control or packages without a
    # Testsuite: field in debian/control might still have autopkgtests as they
    # are generated by autodep8. We will not attempt to recreate the autodep8
    # heuristics here and thus we will always run autopkgtest if
    # RUN_AUTOPKGTEST was set to true. Also see
    # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=916924

    my $autopkgtest = $self->get_conf('AUTOPKGTEST');
    my @autopkgtest_command;
    # The default value is the empty array.
    # If the value is the default (empty array) prefix with 'sudo --'
    # If the value is a non-empty array, prefix with its values except if the
    # first value is an empty string in which case, prefix with nothing
    # If the value is not an array, prefix with that scalar except if the
    # scalar is the empty string in which case, prefix with nothing
    if (ref($self->get_conf('AUTOPKGTEST_ROOT_ARGS')) eq "ARRAY") {
	if (scalar(@{$self->get_conf('AUTOPKGTEST_ROOT_ARGS')}) == 0) {
	    push @autopkgtest_command, 'sudo', '--';
	} elsif (@{$self->get_conf('AUTOPKGTEST_ROOT_ARGS')}[0] eq '') {
	    # do nothing if the first array element is the empty string
	} else {
	    push @autopkgtest_command, @{$self->get_conf('AUTOPKGTEST_ROOT_ARGS')};
	}
    } elsif ($self->get_conf('AUTOPKGTEST_ROOT_ARGS') eq '') {
	# do nothing if the configuration value is the empty string
    } else {
	push @autopkgtest_command, $self->get_conf('AUTOPKGTEST_ROOT_ARGS');
    }
    push @autopkgtest_command, $autopkgtest;
    my $tmpdir;
    my @cwd_files;
    # If the source package was not instructed to be built, then it will not
    # be part of the .changes file and thus, the .dsc has to be passed to
    # autopkgtest in addition to the .changes file.
    if (!$self->get_conf('BUILD_SOURCE')) {
	my $dsc = $self->get('DSC');
	# If the source package was downloaded by sbuild, then the .dsc
	# and the files it references have to be made available to the
	# host
	if (! -f $dsc || ! -r $dsc) {
	    my $build_dir = $self->get('Build Dir');
	    $tmpdir = mkdtemp("/tmp/tmp.sbuild.XXXXXXXXXX");
	    if (!$session->copy_from_chroot("$build_dir/$dsc", "$tmpdir/$dsc")) {
		$self->log_error("cannot copy .dsc from chroot\n");
		rmdir $tmpdir;
		return 0;
	    }
	    @cwd_files = dsc_files("$tmpdir/$dsc");
	    foreach (@cwd_files) {
		if (!$session->copy_from_chroot("$build_dir/$_", "$tmpdir/$_")) {
		    $self->log_error("cannot copy $_ from chroot\n");
		    unlink "$tmpdir/$.dsc";
		    foreach (@cwd_files) {
			unlink "$tmpdir/$_" if -f "$tmpdir/$_";
		    }
		    rmdir $tmpdir;
		    return 0;
		}
	    }
	    $dsc = "$tmpdir/$dsc";
	}
	push @autopkgtest_command, $dsc;
    }
    push @autopkgtest_command, $self->get('Changes File');
    if (scalar(@{$self->get_conf('AUTOPKGTEST_OPTIONS')})) {
	push @autopkgtest_command, @{$self->get_conf('AUTOPKGTEST_OPTIONS')};
    } else {
	push @autopkgtest_command, '--', 'null';
    }
    $self->get('Host')->run_command(
        { COMMAND => \@autopkgtest_command,
          PRIORITY => 0,
        });
    my $status = $? >> 8;
    # if the source package wasn't built and also initially downloaded by
    # sbuild, then the temporary directory that was created must be removed
    if (defined $tmpdir) {
	my $dsc = $self->get('DSC');
	unlink "$tmpdir/$dsc";
	foreach (@cwd_files) {
	    unlink "$tmpdir/$_";
	}
	rmdir $tmpdir;
    }

    # We must check for Ctrl+C (and other aborting signals) directly after
    # running the command so that we do not mark the autopkgtest as successful
    # (the exit status will be zero)
    # But we must check only after the temporary directory has been removed.
    $self->check_abort();

    $self->log("\n");

    if ($status == 0 || $status == 2) { # 2 is "at least one test was skipped (or at least one flaky test failed)"
	$self->set('Autopkgtest Reason', 'pass');
    } elsif ($status == 8) {
	$self->set('Autopkgtest Reason', 'no tests');
    } else {
	# fail if neither all tests passed nor was the package without tests
	$self->log_error("Autopkgtest run failed.\n");
	return 0;
    }

    $self->log_info("Autopkgtest run was successful.\n");
    return 1;
}

sub explain_bd_uninstallable {
    my $self = shift;

    my $resolver = $self->get('Dependency Resolver');

    my $dummy_pkg_name = $resolver->get_sbuild_dummy_pkg_name('main');

    if (!defined $self->get_conf('BD_UNINSTALLABLE_EXPLAINER')) {
	return 0;
    } elsif ($self->get_conf('BD_UNINSTALLABLE_EXPLAINER') eq '') {
	return 0;
    } elsif ($self->get_conf('BD_UNINSTALLABLE_EXPLAINER') eq 'apt') {
	my (@instd, @rmvd);
	my @apt_args = ('--simulate', \@instd, \@rmvd, 'install', $dummy_pkg_name,
	    '-oDebug::pkgProblemResolver=true', '-oDebug::pkgDepCache::Marker=1',
	    '-oDebug::pkgDepCache::AutoInstall=1', '-oDebug::BuildDeps=1'
	);
	$resolver->run_apt(@apt_args);
    } elsif ($self->get_conf('BD_UNINSTALLABLE_EXPLAINER') eq 'dose3') {
	# To retrieve all Packages files apt knows about we use "apt-get
	# indextargets" and "apt-helper cat-file". The former is able to
	# report the filesystem path of all input Packages files. The latter
	# is able to decompress the files if necessary.
	#
	# We do not use "apt-cache dumpavail" or convert the EDSP output to a
	# Packages file because that would make the package selection subject
	# to apt pinning. This limitation would be okay if there was only the
	# apt resolver but since there also exists the aptitude and aspcud
	# resolvers which are able to find solution without pinning
	# restrictions, we don't want to limit ourselves by it. In cases where
	# apt cannot find a solution, this check is supposed to allow the user
	# to know that choosing a different resolver might fix the problem.
	$resolver->add_dependencies('DOSE3', 'dose-distcheck:native', "", "", "", "", "");
	if (!$resolver->install_deps('dose3', 'DOSE3')) {
	    return 0;
	}

	my $session = $self->get('Session');
	my $pipe_apt = $session->pipe_command({
		COMMAND => [ 'apt-get', 'indextargets', '--format', '$(FILENAME)', 'Created-By: Packages' ],
		USER => $self->get_conf('BUILD_USER'),
	    });
	if (!$pipe_apt) {
	    $self->log_error("cannot open reading pipe from apt-get indextargets\n");
	    return 0;
	}

	my $host = $self->get_conf('HOST_ARCH');
	my $build = $self->get_conf('BUILD_ARCH');
	my @debforeignarg = ();
	if ($build ne $host) {
	    @debforeignarg = ('--deb-foreign-archs', $host);
	}

	# - We run dose-debcheck instead of dose-builddebcheck because we want
	#   to check the dummy binary package created by sbuild instead of the
	#   original source package Build-Depends.
	# - We use dose-debcheck instead of dose-distcheck because we cannot
	#   use the deb:// prefix on data from standard input.
	my $pipe_dose = $session->pipe_command({
		COMMAND => ['dose-debcheck',
		    '--checkonly', "$dummy_pkg_name:$host", '--verbose',
		    '--failures', '--successes', '--explain',
		    '--deb-native-arch', $self->get_conf('BUILD_ARCH'), @debforeignarg ],
		PRIORITY => 0,
		USER => $self->get_conf('BUILD_USER'),
		PIPE => 'out'
	    });
	if (!$pipe_dose) {
	    $self->log_error("cannot open writing pipe to dose-debcheck\n");
	    return 0;
	}

	# We parse file by file instead of concatenating all files because if
	# there are many files, we might exceed the maximum command length and
	# it avoids having to have the data from all Packages files in memory
	# all at once. Working with a smaller Dpkg::Index structure should
	# also result in faster store and retrieval times.
	while (my $fname = <$pipe_apt>) {
	    chomp $fname;
	    my $pipe_cat = $session->pipe_command({
		    COMMAND => [ '/usr/lib/apt/apt-helper', 'cat-file', $fname ],
		    USER => $self->get_conf('BUILD_USER'),
		});
	    if (!$pipe_cat) {
		$self->log_error("cannot open reading pipe from apt-helper\n");
		return 0;
	    }

	    # For native compilation we just pipe the output of apt-helper to
	    # dose3. For cross compilation we need to filter foreign
	    # architecture packages that are Essential:yes or
	    # Multi-Arch:foreign or otherwise dose3 might present a solution
	    # that installs foreign architecture Essential:yes or
	    # Multi-Arch:foreign packages.
	    if ($build eq $host) {
		File::Copy::copy $pipe_cat, $pipe_dose;
	    } else {
		my $key_func = sub {
		    return $_[0]->{Package} . ' ' . $_[0]->{Version} . ' ' . $_[0]->{Architecture};
		};

		my $index = Dpkg::Index->new(get_key_func=>$key_func);

		if (!$index->parse($pipe_cat, 'apt-helper cat-file')) {
		    $self->log_error("Cannot parse output of apt-helper cat-file: $!\n");
		    return 0;
		}

		foreach my $key ($index->get_keys()) {
		    my $cdata = $index->get_by_key($key);
		    my $arch = $cdata->{'Architecture'} // '';
		    my $ess = $cdata->{'Essential'} // '';
		    my $ma = $cdata->{'Multi-Arch'} // '';
		    if ($arch ne 'all' && $arch ne $build
			&& ($ess eq 'yes' || $ma eq 'foreign')) {
			next;
		    }
		    $cdata->output($pipe_dose);
		    print $pipe_dose "\n";
		}
	    }

	    close($pipe_cat);
	    if (($? >> 8) != 0) {
		$self->log_error("apt-helper failed\n");
		return 0;
	    }
	}

	close $pipe_dose;
	# - We expect an exit code of less than 64 of dose-debcheck. Any other
	#   exit code indicates abnormal program termination.
	if (($? >> 8) >= 64) {
	    $self->log_error("dose-debcheck failed\n");
	    return 0;
	}

	close $pipe_apt;
	if (($? >> 8) != 0) {
	    $self->log_error("apt-get indextargets failed\n");
	    return 0;
	}


    }

    return 1;
}

sub build {
    my $self = shift;

    my $dscfile = $self->get('DSC File');
    my $dscdir = $self->get('DSC Dir');
    my $pkg = $self->get('Package');
    my $build_dir = $self->get('Build Dir');
    my $host_arch = $self->get('Host Arch');
    my $build_arch = $self->get('Build Arch');
    my $session = $self->get('Session');

    my( $rv, $changes );
    local( *PIPE, *F, *F2 );

    $self->log_subsection("Build");
    $self->set('This Space', 0);

    my $tmpunpackdir = $dscdir;
    $tmpunpackdir =~ s/-.*$/.orig.tmp-nest/;
    $tmpunpackdir =~ s/_/-/;
    $tmpunpackdir = "$build_dir/$tmpunpackdir";

    $dscdir = "$build_dir/$dscdir";

    $self->log_subsubsection("Unpack source");
    if ($session->test_directory($dscdir) && $session->test_symlink($dscdir)) {
	# if the package dir already exists but is a symlink, complain
	$self->log_error("Cannot unpack source: a symlink to a directory with the\n".
		   "same name already exists.\n");
	return 0;
    }
    my $dsccontent = $session->read_file("$build_dir/$dscfile");
    if (!$dsccontent) {
	$self->log_error("Cannot read $build_dir/$dscfile\n");
    } else {
	$self->log($dsccontent);
	$self->log("\n");
    }
    if (!$session->test_directory($dscdir)) {
	$self->set('Sub Task', "dpkg-source");
	$session->run_command({
		COMMAND => [$self->get_conf('DPKG_SOURCE'),
		    '-x', $dscfile, $dscdir],
		USER => $self->get_conf('BUILD_USER'),
		DIR => $build_dir,
		PRIORITY => 0});
	if ($?) {
	    $self->log_error("FAILED [dpkg-source died]\n");
	    Sbuild::Exception::Build->throw(error => "FAILED [dpkg-source died]",
					    failstage => "unpack");
	}

	if (!$session->chmod($dscdir, 'g-s,go+rX', { RECURSIVE => 1 })) {
	    $self->log_error("chmod -R g-s,go+rX $dscdir failed.\n");
	    Sbuild::Exception::Build->throw(error => "chmod -R g-s,go+rX $dscdir failed",
					    failstage => "unpack");
	}
    }
    else {
	$self->log_subsubsection("Check unpacked source");
	# check if the unpacked tree is really the version we need
	my $clog = $session->read_command(
	    { COMMAND => ['dpkg-parsechangelog'],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0,
	      DIR => $dscdir});
	if (!$clog) {
	    $self->log_error("unable to read from dpkg-parsechangelog\n");
	    Sbuild::Exception::Build->throw(error => "unable to read from dpkg-parsechangelog",
					    failstage => "check-unpacked-version");
	}
	$self->set('Sub Task', "dpkg-parsechangelog");

	if ($clog !~ /^Version:\s*(.+)\s*$/mi) {
	    $self->log_error("dpkg-parsechangelog didn't print Version:\n");
	    Sbuild::Exception::Build->throw(error => "dpkg-parsechangelog didn't print Version:",
					    failstage => "check-unpacked-version");
	}
    }

    $self->log_subsubsection("Check disk space");
    chomp(my $current_usage = $session->read_command({ COMMAND => ["du", "-k", "-s", "$dscdir"]}));
    if ($?) {
	$self->log_error("du exited with non-zero exit status $?\n");
	Sbuild::Exception::Build->throw(error => "du exited with non-zero exit status $?", failstage => "check-space");
    }
    $current_usage =~ /^(\d+)/;
    $current_usage = $1;
    if ($current_usage) {
	my $pipe = $session->pipe_command({ COMMAND => ["df", "-k", "$dscdir"]});
	my $free;
	while (<$pipe>) {
	    $free = (split /\s+/)[3];
	}
	close $pipe;
	if ($?) {
	    $self->log_error("df exited with non-zero exit status $?\n");
	    Sbuild::Exception::Build->throw(error => "df exited with non-zero exit status $?", failstage => "check-space");
	}
	if ($free < 2*$current_usage && $self->get_conf('CHECK_SPACE')) {
	    Sbuild::Exception::Build->throw(error => "Disk space is probably not sufficient for building.",
		info => "Source needs $current_usage KiB, while $free KiB is free.)",
		failstage => "check-space");
	} else {
	    $self->log("Sufficient free space for build\n");
	}
    }

    my $clogpipe = $session->pipe_command(
	{ COMMAND => ['dpkg-parsechangelog'],
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0,
	  DIR => $dscdir });
    if (!$clogpipe) {
	    $self->log_error("unable to read from dpkg-parsechangelog\n");
	    Sbuild::Exception::Build->throw(error => "unable to read from dpkg-parsechangelog",
					    failstage => "check-unpacked-version");
    }

    my $clog = Dpkg::Control->new(type => CTRL_CHANGELOG);
    if (!$clog->parse($clogpipe, "$dscdir/debian/changelog")) {
	$self->log_error("unable to parse debian/changelog\n");
	Sbuild::Exception::Build->throw(error => "unable to parse debian/changelog",
	    failstage => "check-unpacked-version");
    }

    close($clogpipe);

    my $name = $clog->{Source};
    my $version = $clog->{Version};
    my $dists = $clog->{Distribution};
    my $urgency = $clog->{Urgency};

    if ($dists ne $self->get_conf('DISTRIBUTION')) {
	$self->build_log_colour('yellow',
				"^Distribution: " . $self->get_conf('DISTRIBUTION') . "\$");
    }

    if ($self->get_conf('BIN_NMU') || $self->get_conf('APPEND_TO_VERSION')
	|| defined $self->get_conf('BIN_NMU_CHANGELOG')) {
	$self->log_subsubsection("Hack binNMU version");

	my $text = $session->read_file("$dscdir/debian/changelog");

	if (!$text) {
	    $self->log_error("Can't open debian/changelog -- no binNMU hack!\n");
	    Sbuild::Exception::Build->throw(error => "Can't open debian/changelog -- no binNMU hack: $!!",
		failstage => "hack-binNMU");
	}

	my $NMUversion = $self->get('Version');

	my $clogpipe = $session->get_write_file_handle("$dscdir/debian/changelog");

	if (!$clogpipe) {
	    $self->log_error("Can't open debian/changelog for binNMU hack: $!\n");
	    Sbuild::Exception::Build->throw(error => "Can't open debian/changelog for binNMU hack: $!",
		failstage => "hack-binNMU");
	}
	if (defined $self->get_conf('BIN_NMU_CHANGELOG')) {
	    my $clogentry = $self->get_conf('BIN_NMU_CHANGELOG');
	    # trim leading and trailing whitespace and linebreaks
	    $clogentry =~ s/^\s+|\s+$//g;
	    print $clogpipe $clogentry . "\n\n";
	} else {
	    if (!$self->get_conf('MAINTAINER_NAME')) {
		Sbuild::Exception::Build->throw(error => "No maintainer specified.",
		    info => 'When making changelog additions for a binNMU or appending a version suffix, a maintainer must be specified for the changelog entry e.g. using $maintainer_name, $uploader_name or $key_id, (or the equivalent command-line options)',
		    failstage => "check-space");
	    }

	    $dists = $self->get_conf('DISTRIBUTION');

	    print $clogpipe "$name ($NMUversion) $dists; urgency=low, binary-only=yes\n\n";
	    if ($self->get_conf('APPEND_TO_VERSION')) {
		print $clogpipe "  * Append ", $self->get_conf('APPEND_TO_VERSION'),
		" to version number; no source changes\n";
	    }
	    if ($self->get_conf('BIN_NMU')) {
		print $clogpipe "  * Binary-only non-maintainer upload for $host_arch; ",
		"no source changes.\n";
		print $clogpipe "  * ", join( "    ", split( "\n", $self->get_conf('BIN_NMU') )), "\n";
	    }
	    print $clogpipe "\n";

	    # Earlier implementations used the date of the last changelog
	    # entry for the new entry so that Multi-Arch:same packages would
	    # be co-installable (their shared changelogs had to match). This
	    # is not necessary anymore as binNMU changelogs are now written
	    # into architecture specific paths. Re-using the date of the last
	    # changelog entry has the disadvantage that this will effect
	    # SOURCE_DATE_EPOCH which in turn will make the timestamps of the
	    # files in the new package equal to the last version which can
	    # confuse backup programs.  By using the build date for the new
	    # binNMU changelog timestamp we make sure that the timestamps of
	    # changed files inside the new package advanced in comparison to
	    # the last version.
	    #
	    # The timestamp format has to follow Debian Policy §4.4
	    #   https://www.debian.org/doc/debian-policy/ch-source.html#s-dpkgchangelog
	    # which is the same format as `date -R`
	    my $date;
	    if (defined $self->get_conf('BIN_NMU_TIMESTAMP')) {
		if ($self->get_conf('BIN_NMU_TIMESTAMP') =~ /^\+?[1-9]\d*$/) {
		    $date = strftime_c "%a, %d %b %Y %H:%M:%S +0000",
		    gmtime($self->get_conf('BIN_NMU_TIMESTAMP'));
		} else {
		    $date = $self->get_conf('BIN_NMU_TIMESTAMP');
		}
	    } else {
		$date = strftime_c "%a, %d %b %Y %H:%M:%S +0000", gmtime();
	    }
	    print $clogpipe " -- " . $self->get_conf('MAINTAINER_NAME') . "  $date\n\n";
	}
	print $clogpipe $text;
	close($clogpipe);
	$self->log("Created changelog entry for binNMU version $NMUversion\n");
    }

    if ($session->test_regular_file("$dscdir/debian/files")) {
	local( *FILES );
	my @lines;
	my $FILES = $session->get_read_file_handle("$dscdir/debian/files");
	chomp( @lines = <$FILES> );
	close( $FILES );

	$self->log_warning("After unpacking, there exists a file debian/files with the contents:\n");

	$self->log_sep();
	foreach (@lines) {
	    $self->log($_);
	}
	$self->log_sep();
	$self->log("\n");

	$self->log_info("This should be reported as a bug.\n");
	$self->log_info("The file has been removed to avoid dpkg-genchanges errors.\n");

	unlink "$dscdir/debian/files";
    }

    # Build tree not writable during build (except for the sbuild
    # user performing the build).
    if (!$session->chmod($self->get('Build Dir'), 'go-w', { RECURSIVE => 1 })) {
	$self->log_error("chmod og-w " . $self->get('Build Dir') . " failed.\n");
	return 0;
    }

    if (!$self->run_external_commands("starting-build-commands")) {
	Sbuild::Exception::Build->throw(error => "Failed to execute starting-build-commands",
	    failstage => "run-starting-build-commands");
    }

    $self->set('Build Start Time', time);
    $self->set('Build End Time', $self->get('Build Start Time'));

    if ($session->test_regular_file("/etc/ld.so.conf") &&
       ! $session->test_regular_file_readable("/etc/ld.so.conf")) {
	$session->chmod('/etc/ld.so.conf', 'a+r');

	$self->log_subsubsection("Fix ld.so");
	$self->log("ld.so.conf was not readable! Fixed.\n");
    }

    my $buildcmd = [];
    if (length $self->get_conf('BUILD_ENV_CMND') ) {
        push( @{$buildcmd}, $self->get_conf('BUILD_ENV_CMND') );
    }
    push (@{$buildcmd}, 'dpkg-buildpackage');

    my $dpkgversion = version->new(0);
    {
        # we use pipe_command instead of read_command because we want to
        # ignore non-zero exit code without printing an error message from
        # dpkg versions before 1.20 which didn't have --robot
        my $pipe = $session->pipe_command(
            {
                COMMAND   => [ 'dpkg', '--robot', '--version' ],
                STREAMERR => $devnull
            }
        );
        chomp(
            my $content = do { local $/; <$pipe> }
        );
        close $pipe;
        if ( $? == 0 and $content =~ /^([0-9.]+)( .*)?$/ ) {
            # dpkg is new enough for the --robot option
            $dpkgversion = version->new($1);
        }
    }
    # since dpkg 1.20.0
    # will reset environment and umask to their vendor specific defaults
    if ($dpkgversion >= "1.20.0") {
	push (@{$buildcmd}, '--sanitize-env');
    }

    if ($host_arch ne $build_arch) {
	push (@{$buildcmd}, '-a' . $host_arch);
    }

    if (length $self->get_conf('BUILD_PROFILES')) {
	my $profiles = $self->get_conf('BUILD_PROFILES');
	$profiles =~ tr/ /,/;
	push (@{$buildcmd}, '-P' . $profiles);
    }

    if (defined $self->get_conf('PGP_OPTIONS')) {
	if (ref($self->get_conf('PGP_OPTIONS')) eq 'ARRAY') {
	    push (@{$buildcmd}, @{$self->get_conf('PGP_OPTIONS')});
        } elsif (length $self->get_conf('PGP_OPTIONS')) {
	    push (@{$buildcmd}, $self->get_conf('PGP_OPTIONS'));
	}
    }

    if (defined $self->get_conf('SIGNING_OPTIONS')) {
	if (ref($self->get_conf('SIGNING_OPTIONS')) eq 'ARRAY') {
	    push (@{$buildcmd}, @{$self->get_conf('SIGNING_OPTIONS')});
        } elsif (length $self->get_conf('SIGNING_OPTIONS')) {
	    push (@{$buildcmd}, $self->get_conf('SIGNING_OPTIONS'));
	}
    }

    use constant dpkgopt => [[["", "-B"], ["-A", "-b" ]], [["-S", "-G"], ["-g", ""]]];
    my $binopt = dpkgopt->[$self->get_conf('BUILD_SOURCE')]
			  [$self->get_conf('BUILD_ARCH_ALL')]
			  [$self->get_conf('BUILD_ARCH_ANY')];
    push (@{$buildcmd}, $binopt) if $binopt;
    push (@{$buildcmd}, "-r" . $self->get_conf('FAKEROOT'));

    if ($self->get_conf('DPKG_FILE_SUFFIX')) {
	my $dpkg_version_ok = Dpkg::Version->new("1.18.11");
	if ($self->get('Dpkg Version') >= $dpkg_version_ok) {
	    my $changes = $self->get_changes();
	    push (@{$buildcmd}, "--changes-option=-O../$changes");
	    my $buildinfo = $self->get_buildinfo();
	    push (@{$buildcmd}, "--buildinfo-option=-O../$buildinfo");
	} else {
	    $self->log("Ignoring dpkg file suffix: dpkg version too old\n");
	    $self->set_conf('DPKG_FILE_SUFFIX',undef);
	}
    }

    if (defined $self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')) {
	push (@{$buildcmd}, @{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')});
    }

    # Set up additional build environment variables.
    my %buildenv = %{$self->get_conf('BUILD_ENVIRONMENT')};
    $buildenv{'PATH'} = $self->get_conf('PATH');
    $buildenv{'LD_LIBRARY_PATH'} = $self->get_conf('LD_LIBRARY_PATH')
	if defined($self->get_conf('LD_LIBRARY_PATH'));

	# Add cross environment config
	if ($host_arch ne $build_arch) {
		$buildenv{'CONFIG_SITE'} = "/etc/dpkg-cross/cross-config." . $host_arch;
		# when cross-building, only set "nocheck" if DEB_BUILD_OPTIONS
		# was not already set. This allows overwriting the default by
		# setting the DEB_BUILD_OPTIONS environment variable
		if (!defined($ENV{'DEB_BUILD_OPTIONS'})) {
			$ENV{'DEB_BUILD_OPTIONS'} = "nocheck";
		}
	}

    # Explicitly add any needed environment to the environment filter
    # temporarily for dpkg-buildpackage.
    my @env_filter;
    foreach my $envvar (keys %buildenv) {
	push(@env_filter, "^$envvar\$");
    }

    # Dump build environment
    $self->log_subsubsection("User Environment");
    {
	my $envcmd = $session->read_command(
	    { COMMAND => ['env'],
	      ENV => \%buildenv,
	      ENV_FILTER => \@env_filter,
	      USER => $self->get_conf('BUILD_USER'),
	      SETSID => 1,
	      PRIORITY => 0,
	      DIR => $dscdir
	    });
	if (!$envcmd) {
	    $self->log_error("unable to open pipe\n");
	    Sbuild::Exception::Build->throw(error => "unable to open pipe",
					    failstage => "dump-build-env");
	}

	my @lines=sort(split /\n/, $envcmd);
	foreach my $line (@lines) {
	    $self->log("$line\n");
	}
    }

    $self->log_subsubsection("dpkg-buildpackage");
    $self->log("Command: " . join(' ', @{$buildcmd}) . "\n");

    my $command = {
	COMMAND => $buildcmd,
	ENV => \%buildenv,
	ENV_FILTER => \@env_filter,
	USER => $self->get_conf('BUILD_USER'),
	SETSID => 1,
	PRIORITY => 0,
	DIR => $dscdir,
	STREAMERR => \*STDOUT,
	DISABLE_NETWORK => 1,
    };

    my $pipe = $session->pipe_command($command);
    if (!$pipe) {
	$self->log_error("unable to open pipe\n");
	Sbuild::Exception::Build->throw(error => "unable to open pipe",
	    failstage => "dpkg-buildpackage");
    }

    $self->set('dpkg-buildpackage pid', $command->{'PID'});
    $self->set('Sub Task', "dpkg-buildpackage");

    my $timeout = $self->get_conf('INDIVIDUAL_STALLED_PKG_TIMEOUT')->{$pkg} ||
	$self->get_conf('STALLED_PKG_TIMEOUT');
    $timeout *= 60;
    my $timed_out = 0;
    my(@timeout_times, @timeout_sigs, $last_time);

    local $SIG{'ALRM'} = sub {
	my $pid = $self->get('dpkg-buildpackage pid');
	my $signal = ($timed_out > 0) ? "KILL" : "TERM";
	# negative pid to send to whole process group
	kill "$signal", -$pid;

	$timeout_times[$timed_out] = time - $last_time;
	$timeout_sigs[$timed_out] = $signal;
	$timed_out++;
	$timeout = 5*60; # only wait 5 minutes until next signal
    };

    alarm($timeout);
    # We do not use a while(<$pipe>) {} loop because that one would only read
    # full lines (until $/ is reached). But we do not want to tie "activity"
    # to receiving complete lines on standard output and standard error.
    # Receiving any data should be sufficient for a process to signal that it
    # is still active. Thus, instead of reading lines, we use sysread() which
    # will return us data once it is available even if the data is not
    # terminated by a newline. To still print correctly to the log, we collect
    # unterminated strings into an accumulator and print them to the log once
    # the newline shows up. This has the added advantage that we can now not
    # only treat \n as producing new lines ($/ is limited to a single
    # character) but can also produce new lines when encountering a \r as it
    # is common for progress-meter output of long-running processes.
    my $acc = "";
    while(1) {
	alarm($timeout);
	$last_time = time;
	# The buffer size is really arbitrary and just makes sure not to call
	# this function too often if lots of data is produced by the build.
	# The function will immediately return even with less data than the
	# buffer size once it is available.
	my $ret = sysread($pipe, my $buf, 1024);
	# sysread failed - this for example happens when the build timeouted
	# and is killed as a result
	if (!defined $ret) {
	    last;
	}
	# A return value of 0 signals EOF
	if ($ret == 0) {
	    last;
	}
	# We choose that lines shall not only be terminated by \n but that new
	# log lines are also produced after encountering a \r.
	# A negative limit is used to also produce trailing empty fields if
	# required (think of multiple trailing empty lines).
	my @parts = split /\r|\n/, $buf, -1;
	my $numparts = scalar @parts;
	if ($numparts == 1) {
	    # line terminator was not found
	    $acc .= $buf;
	} elsif ($numparts >= 2) {
	    # first match needs special treatment as it needs to be
	    # concatenated with $acc
	    my $first = shift @parts;
	    $self->log($acc . $first . "\n");
	    my $last = pop @parts;
	    for (my $i = 0; $i < $numparts - 2; $i++) {
		$self->log($parts[$i] . "\n");
	    }
	    # the last part is put into the accumulator. This might
	    # just be the empty string if $buf ended in a line
	    # terminator
	    $acc = $last;
	}
    }
    # If the output didn't end with a line terminator, just print out the rest
    # as we have it.
    if ($acc ne "") {
	$self->log($acc . "\n");
    }
    close($pipe);
    alarm(0);
    $rv = $?;
    $self->set('dpkg-buildpackage pid', undef);

    my $i;
    for( $i = 0; $i < $timed_out; ++$i ) {
	$self->log_error("Build killed with signal " . $timeout_sigs[$i] .
	           " after " . int($timeout_times[$i]/60) .
	           " minutes of inactivity\n");
    }
    $self->set('Build End Time', time);
    $self->set('Pkg End Time', time);
    $self->set('This Time', $self->get('Pkg End Time') - $self->get('Pkg Start Time'));
    $self->set('This Time', 0) if $self->get('This Time') < 0;

    $self->write_stats('build-time',
		       $self->get('Build End Time')-$self->get('Build Start Time'));
    $self->write_stats('install-download-time',
		       $self->get('Install End Time')-$self->get('Install Start Time'));
    my $finish_date = strftime_c "%FT%TZ", gmtime($self->get('Build End Time'));
    $self->log_sep();
    $self->log("Build finished at $finish_date\n");


    if (!$self->run_external_commands("finished-build-commands")) {
	Sbuild::Exception::Build->throw(error => "Failed to execute finished-build-commands",
	    failstage => "run-finished-build-commands");
    }

    my @space_files = ();

    $self->log_subsubsection("Finished");
    if ($rv) {
	Sbuild::Exception::Build->throw(error => "Build failure (dpkg-buildpackage died)",
	    failstage => "build");
    } else {
	$self->log_info("Built successfully\n");

	if ($session->test_regular_file_readable("$dscdir/debian/files")) {
	    my @files = $self->debian_files_list("$dscdir/debian/files");

	    foreach (@files) {
		if (!$session->test_regular_file("$build_dir/$_")) {
		    $self->log_error("Package claims to have built ".basename($_).", but did not.  This is a bug in the packaging.\n");
		    next;
		}
		if (/_all.u?deb$/ and not $self->get_conf('BUILD_ARCH_ALL')) {
		    $self->log_error("Package builds ".basename($_)." when binary-indep target is not called.  This is a bug in the packaging.\n");
		    $session->unlink("$build_dir/$_");
		    next;
		}
	    }
	}

	# Restore write access to build tree now build is complete.
	if (!$session->chmod($self->get('Build Dir'), 'g+w', { RECURSIVE => 1 })) {
	    $self->log_error("chmod g+w " . $self->get('Build Dir') . " failed.\n");
	    return 0;
	}

	$self->log_subsection("Changes");

	# we use an anonymous subroutine so that the referenced variables are
	# automatically rebound to their current values
	my $copy_changes = sub {
	    my $changes = shift;

	    my $F = $session->get_read_file_handle("$build_dir/$changes");
	    if (!$F) {
		$self->log_error("cannot get read file handle for $build_dir/$changes\n");
		Sbuild::Exception::Build->throw(error => "cannot get read file handle for $build_dir/$changes",
		    failstage => "parse-changes");
	    }
	    my $pchanges = Dpkg::Control->new(type => CTRL_FILE_CHANGES);
	    if (!$pchanges->parse($F, "$build_dir/$changes")) {
		$self->log_error("cannot parse $build_dir/$changes\n");
		Sbuild::Exception::Build->throw(error => "cannot parse $build_dir/$changes",
		    failstage => "parse-changes");
	    }
	    close($F);


	    if ($self->get_conf('OVERRIDE_DISTRIBUTION')) {
		$pchanges->{Distribution} = $self->get_conf('DISTRIBUTION');
	    }

	    my $sys_build_dir = $self->get_conf('BUILD_DIR');
	    my $F2 = $session->get_write_file_handle("$build_dir/$changes.new");
	    if (!$F2) {
		$self->log("Cannot create $build_dir/$changes.new\n");
		$self->log("Distribution field may be wrong!!!\n");
		if ($build_dir) {
		    if(!$session->copy_from_chroot("$build_dir/$changes", ".")) {
			$self->log_error("Could not copy $build_dir/$changes to .\n");
		    }
		}
	    } else {
		$pchanges->output(\*STDOUT);
		$pchanges->output(\*$F2);

		close( $F2 );

		$session->rename("$build_dir/$changes.new", "$build_dir/$changes");
		if ($?) {
		    $self->log("$build_dir/$changes.new could not be " .
			    "renamed to $build_dir/$changes: $?\n");
		    $self->log("Distribution field may be wrong!!!");
		}
		if ($build_dir) {
		    if (!$session->copy_from_chroot("$build_dir/$changes", "$sys_build_dir")) {
			$self->log("Could not copy $build_dir/$changes to $sys_build_dir");
		    }
		}
	    }

	    return $pchanges;
	};

	$changes = $self->get_changes();
	if (!defined($changes)) {
	    $self->log_error(".changes is undef. Cannot copy build results.\n");
	    return 0;
	}
	my @cfiles;
	if ($session->test_regular_file_readable("$build_dir/$changes")) {
	    my(@do_dists, @saved_dists);
	    $self->log_subsubsection("$changes:");

	    my $pchanges = &$copy_changes($changes);
	    $self->set('Changes File', $self->get_conf('BUILD_DIR') . "/$changes");

	    my $checksums = Dpkg::Checksums->new();
	    $checksums->add_from_control($pchanges);

	    push(@cfiles, $checksums->get_files());

	}
	else {
	    $self->log_error("Can't find $changes -- can't dump info\n");
	}

	if ($self->get_conf('SOURCE_ONLY_CHANGES')) {
	    my $so_changes = $self->get('Package_SVersion') . "_source.changes";
	    $self->log_subsubsection("$so_changes:");
	    my $genchangescmd = ['dpkg-genchanges', '--build=source'];
	    if (defined $self->get_conf('SIGNING_OPTIONS')) {
		if (ref($self->get_conf('SIGNING_OPTIONS')) eq 'ARRAY') {
		    push (@{$genchangescmd}, @{$self->get_conf('SIGNING_OPTIONS')});
		} elsif (length $self->get_conf('SIGNING_OPTIONS')) {
		    push (@{$genchangescmd}, $self->get_conf('SIGNING_OPTIONS'));
		}
	    }
	    my $changes_opts = $self->get_changes_opts();
	    if ($changes_opts) {
		    push (@{$genchangescmd}, @{$changes_opts});
	    }
	    my $cfile = $session->read_command(
		{ COMMAND => $genchangescmd,
		    USER => $self->get_conf('BUILD_USER'),
		    PRIORITY => 0,
		    DIR => $dscdir});
	    if (!$cfile) {
		$self->log_error("dpkg-genchanges --build=source failed\n");
		Sbuild::Exception::Build->throw(error => "dpkg-genchanges --build=source failed",
		    failstage => "source-only-changes");
	    }
	    if (!$session->write_file("$build_dir/$so_changes", $cfile)) {
		$self->log_error("cannot write content to $build_dir/$so_changes\n");
		Sbuild::Exception::Build->throw(error => "cannot write content to $build_dir/$so_changes",
		    failstage => "source-only-changes");
	    }

	    my $pchanges = &$copy_changes($so_changes);
	}

	$self->log_subsection("Buildinfo");

	foreach (@cfiles) {
	    my $deb = "$build_dir/$_";
	    next if $deb !~ /\.buildinfo$/;
	    my $buildinfo = $session->read_file($deb);
	    if (!$buildinfo) {
		$self->log_error("Cannot read $deb\n");
	    } else {
		$self->log($buildinfo);
		$self->log("\n");
	    }
	}

	$self->log_subsection("Package contents");

	my @debcfiles = @cfiles;
	foreach (@debcfiles) {
	    my $deb = "$build_dir/$_";
	    next if $deb !~ /(\Q$host_arch\E|all)\.(udeb|deb)$/;

	    $self->log_subsubsection("$_");
	    my $dpkg_info = $session->read_command({COMMAND => ["dpkg", "--info", $deb]});
	    if (!$dpkg_info) {
		$self->log_error("Can't spawn dpkg: $! -- can't dump info\n");
	    }
	    else {
		$self->log($dpkg_info);
	    }
	    $self->log("\n");
	    my $dpkg_contents = $session->read_command({COMMAND => ["sh", "-c", "dpkg --contents $deb 2>&1 | sort -k6"]});
	    if (!$dpkg_contents) {
		$self->log_error("Can't spawn dpkg: $! -- can't dump info\n");
	    }
	    else {
		$self->log($dpkg_contents);
	    }
	    $self->log("\n");
	}

	foreach (@cfiles) {
	    push( @space_files, $self->get_conf('BUILD_DIR') . "/$_");
	    if (!$session->copy_from_chroot("$build_dir/$_", $self->get_conf('BUILD_DIR'))) {
		$self->log_error("Could not copy $build_dir/$_ to " . $self->get_conf('BUILD_DIR') . "\n");
	    }
	}
    }

    $self->set('This Space', $self->check_space(@space_files));

    return $rv == 0 ? 1 : 0;
}

# Produce a hash suitable for ENV export
sub get_env ($$) {
    my $self = shift;
    my $prefix = shift;

    sub _env_loop ($$$$) {
	my ($env,$ref,$keysref,$prefix) = @_;

	foreach my $key (keys( %{ $keysref } )) {
	    my $value = $ref->get($key);
	    next if (!defined($value));
	    next if (ref($value));
	    my $name = "${prefix}${key}";
	    $name =~ s/ /_/g;
	    $env->{$name} = $value;
        }
    }

    my $envlist = {};
    _env_loop($envlist, $self, $self, $prefix);
    _env_loop($envlist, $self->get('Config'), $self->get('Config')->{'KEYS'}, "${prefix}CONF_");
    return $envlist;
}

sub get_build_filename {
    my $self=shift;
    my $filetype=shift;
    my $changes = $self->get('Package_SVersion');

    if ($self->get_conf('BUILD_ARCH_ANY')) {
	$changes .= '_' . $self->get('Host Arch');
    } elsif ($self->get_conf('BUILD_ARCH_ALL')) {
	$changes .= "_all";
    } elsif ($self->get_conf('BUILD_SOURCE')) {
	$changes .= "_source";
    }

    my $suffix = $self->get_conf('DPKG_FILE_SUFFIX');
    $changes .= $suffix if ($suffix);

    $changes .= '.' . $filetype;

    return $changes;
}

sub get_changes {
    my $self=shift;
    return $self->get_build_filename("changes");
}

sub get_buildinfo {
    my $self=shift;
    return $self->get_build_filename("buildinfo");
}

sub check_space {
    my $self = shift;
    my @files = @_;
    my $sum = 0;

    my $dscdir = $self->get('DSC Dir');
    return -1 unless (defined $dscdir);

    my $build_dir = $self->get('Build Dir');
    my $pkgbuilddir = "$build_dir/$dscdir";

    # if the source package was not yet unpacked, we will not attempt to compute
    # the required space.
    return -1 unless ($self->get('Session')->test_directory($pkgbuilddir));

    my ($space, $spacenum);

    # get the required space for the unpacked source package in the chroot
    $space = $self->get('Session')->read_command(
	{ COMMAND => ['du', '-k', '-s', $pkgbuilddir],
	    USER => $self->get_conf('USERNAME'),
	    PRIORITY => 0,
	    DIR => '/'});

    if (!$space) {
	$self->log_error("Cannot determine space needed for $pkgbuilddir (du failed)\n");
	return -1;
    }
    # remove the trailing path from the du output
    if (($spacenum) = $space =~ /^(\d+)/) {
	$sum += $spacenum;
    } else {
	$self->log_error("Cannot determine space needed for $pkgbuilddir (unexpected du output): $space\n");
	return -1;
    }

    # get the required space for all produced build artifacts on the host
    # running sbuild
    foreach my $file (@files) {
	$space = $self->get('Host')->read_command(
	    { COMMAND => ['du', '-k', '-s', $file],
	      USER => $self->get_conf('USERNAME'),
	      PRIORITY => 0,
	      DIR => '/'});

	if (!$space) {
	    $self->log_error("Cannot determine space needed for $file (du failed): $!\n");
	    return -1;
	}
	# remove the trailing path from the du output
	if (($spacenum) = $space =~ /^(\d+)/) {
	    $sum += $spacenum;
	} else {
	    $self->log_error("Cannot determine space needed for $file (unexpected du output): $space\n");
	    return -1;
	}
    }

    return $sum;
}

sub lock_file {
    my $self = shift;
    my $file = shift;
    my $for_srcdep = shift;
    my $lockfile = "$file.lock";
    my $try = 0;

  repeat:
    if (!sysopen( F, $lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
	if ($! == EEXIST) {
	    # lock file exists, wait
	    goto repeat if !open( F, "<$lockfile" );
	    my $line = <F>;
	    my ($pid, $user);
	    close( F );
	    if ($line !~ /^(\d+)\s+([\w\d.-]+)$/) {
		$self->log_warning("Bad lock file contents ($lockfile) -- still trying\n");
	    }
	    else {
		($pid, $user) = ($1, $2);
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    # process doesn't exist anymore, remove stale lock
		    $self->log_warning("Removing stale lock file $lockfile ".
				       "(pid $pid, user $user)\n");
		    unlink( $lockfile );
		    goto repeat;
		}
	    }
	    ++$try;
	    if (!$for_srcdep && $try > $self->get_conf('MAX_LOCK_TRYS')) {
		$self->log_warning("Lockfile $lockfile still present after " .
				   $self->get_conf('MAX_LOCK_TRYS') *
				   $self->get_conf('LOCK_INTERVAL') .
				   " seconds -- giving up\n");
		return;
	    }
	    $self->log("Another sbuild process ($pid by $user) is currently installing or removing packages -- waiting...\n")
		if $for_srcdep && $try == 1;
	    sleep $self->get_conf('LOCK_INTERVAL');
	    goto repeat;
	}
	$self->log_warning("Can't create lock file $lockfile: $!\n");
    }

    my $username = $self->get_conf('USERNAME');
    F->print("$$ $username\n");
    F->close();
}

sub unlock_file {
    my $self = shift;
    my $file = shift;
    my $lockfile = "$file.lock";

    unlink( $lockfile );
}

sub add_stat {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    $self->get('Summary Stats')->{$key} = $value;
}

sub generate_stats {
    my $self = shift;
    my $resolver = $self->get('Dependency Resolver');

    $self->add_stat('Job', $self->get('Job'));
    $self->add_stat('Package', $self->get('Package'));
    # If the package fails early, then the version might not yet be known.
    # This can happen if the user only specified a source package name on the
    # command line and then the version will only be known after the source
    # package was successfully downloaded.
    if ($self->get('Version')) {
	$self->add_stat('Version', $self->get('Version'));
    }
    if ($self->get('OVersion')) {
	$self->add_stat('Source-Version', $self->get('OVersion'));
    }
    $self->add_stat('Machine Architecture', $self->get_conf('ARCH'));
    $self->add_stat('Host Architecture', $self->get('Host Arch'));
    $self->add_stat('Build Architecture', $self->get('Build Arch'));
    $self->add_stat('Build Profiles', $self->get('Build Profiles'))
        if $self->get('Build Profiles');
    $self->add_stat('Build Type', $self->get('Build Type'));
    my @keylist;
    if (defined $resolver) {
	@keylist=keys %{$resolver->get('Initial Foreign Arches')};
	push @keylist, keys %{$resolver->get('Added Foreign Arches')};
    }
    my $foreign_arches = join ' ', @keylist;
    $self->add_stat('Foreign Architectures', $foreign_arches )
        if $foreign_arches;
    $self->add_stat('Distribution', $self->get_conf('DISTRIBUTION'));
    if ($self->get('This Space') >= 0) {
	$self->add_stat('Space', $self->get('This Space'));
    } else {
	$self->add_stat('Space', "n/a");
    }
    $self->add_stat('Build-Time',
		    $self->get('Build End Time')-$self->get('Build Start Time'));
    $self->add_stat('Install-Time',
		    $self->get('Install End Time')-$self->get('Install Start Time'));
    $self->add_stat('Package-Time',
		    $self->get('Pkg End Time')-$self->get('Pkg Start Time'));
    if ($self->get('This Space') >= 0) {
	$self->add_stat('Build-Space', $self->get('This Space'));
    } else {
	$self->add_stat('Build-Space', "n/a");
    }
    $self->add_stat('Status', $self->get_status());
    $self->add_stat('Fail-Stage', $self->get('Pkg Fail Stage'))
	if ($self->get_status() ne "successful");
    $self->add_stat('Lintian', $self->get('Lintian Reason'))
	if $self->get('Lintian Reason');
    $self->add_stat('Piuparts', $self->get('Piuparts Reason'))
	if $self->get('Piuparts Reason');
    $self->add_stat('Autopkgtest', $self->get('Autopkgtest Reason'))
	if $self->get('Autopkgtest Reason');
}

sub log_stats {
    my $self = shift;
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	$self->log("${stat}: " . $self->get('Summary Stats')->{$stat} . "\n");
    }
}

sub print_stats {
    my $self = shift;
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	print STDOUT "${stat}: " . $self->get('Summary Stats')->{$stat} . "\n";
    }
}

sub write_stats {
    my $self = shift;

    return if (!$self->get_conf('BATCH_MODE'));

    my $stats_dir = $self->get_conf('STATS_DIR');

    return if not defined $stats_dir;

    if (! -d $stats_dir &&
	!mkdir $stats_dir) {
	$self->log_warning("Could not create $stats_dir: $!\n");
	return;
    }

    my ($cat, $val) = @_;
    local( *F );

    $self->lock_file($stats_dir, 0);
    open( F, ">>$stats_dir/$cat" );
    print F "$val\n";
    close( F );
    $self->unlock_file($stats_dir);
}

sub debian_files_list {
    my $self = shift;
    my $files = shift;

    my @list;

    debug("Parsing $files\n");
    my $session = $self->get('Session');

    my $pipe = $session->get_read_file_handle($files);
    if ($pipe) {
	while (<$pipe>) {
	    chomp;
	    my $f = (split( /\s+/, $_ ))[0];
	    push( @list, "$f" );
	    debug("  $f\n");
	}
	close( $pipe ) or $self->log_error("Failed to close $files\n") && return 1;
    }

    return @list;
}

# Figure out chroot architecture
sub chroot_arch {
    my $self = shift;

    chomp(my $chroot_arch = $self->get('Session')->read_command(
	{ COMMAND => ['dpkg', '--print-architecture'],
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0,
	  DIR => '/' }));

    if (!$chroot_arch) {
	Sbuild::Exception::Build->throw(error => "Can't determine architecture of chroot: $!",
	    failstage => "chroot-arch")
    }

    return $chroot_arch;
}

sub build_log_filter {
    my $self = shift;
    my $text = shift;
    my $replacement = shift;

    if ($self->get_conf('LOG_FILTER')) {
	$self->log($self->get('FILTER_PREFIX') . $text . ':' . $replacement . "\n");
    }
}

sub build_log_colour {
    my $self = shift;
    my $regex = shift;
    my $colour = shift;

    if ($self->get_conf('LOG_COLOUR')) {
	$self->log($self->get('COLOUR_PREFIX') . $colour . ':' . $regex . "\n");
    }
}

sub open_build_log {
    my $self = shift;

    my $date = strftime_c "%FT%TZ", gmtime($self->get('Pkg Start Time'));

    my $filter_prefix = '__SBUILD_FILTER_' . $$ . ':';
    $self->set('FILTER_PREFIX', $filter_prefix);
    my $colour_prefix = '__SBUILD_COLOUR_' . $$ . ':';
    $self->set('COLOUR_PREFIX', $colour_prefix);

    my $filename = $self->get_conf('LOG_DIR') . '/';
    # we might not know the pkgname_ver string if the user only specified a
    # package name without version
    if ($self->get('Package_SVersion')) {
	$filename .= $self->get('Package_SVersion');
    } else {
	$filename .= $self->get('Package');
    }
    $filename .= '_' . $self->get('Host Arch') . "-$date";
    $filename .= ".build" if $self->get_conf('SBUILD_MODE') ne 'buildd';

    open($saved_stdout, ">&STDOUT") or warn "Can't redirect stdout\n";
    open($saved_stderr, ">&STDERR") or warn "Can't redirect stderr\n";

    my $PLOG;

    my $pid;
    ($pid = open($PLOG, "|-"));
    if (!defined $pid) {
	warn "Cannot open pipe to '$filename': $!\n";
    } elsif ($pid == 0) {
	$SIG{'INT'} = 'IGNORE';
	$SIG{'TERM'} = 'IGNORE';
	$SIG{'QUIT'} = 'IGNORE';
	$SIG{'PIPE'} = 'IGNORE';

	$saved_stdout->autoflush(1);
	if (!$self->get_conf('NOLOG') &&
	    $self->get_conf('LOG_DIR_AVAILABLE')) {
	    unlink $filename; # To prevent opening symlink to elsewhere
	    open( CPLOG, ">$filename" ) or
		Sbuild::Exception::Build->throw(error => "Failed to open build log $filename: $!",
						failstage => "init");
	    CPLOG->autoflush(1);

	    # Create 'current' symlinks
	    if ($self->get_conf('SBUILD_MODE') eq 'buildd') {
		$self->log_symlink($filename,
				   $self->get_conf('BUILD_DIR') . '/current-' .
				   $self->get_conf('DISTRIBUTION'));
	    } else {
		my $symlinktarget = $filename;
		# if symlink target is in the same directory as the symlink
		# itself, make it a relative link instead of an absolute one
		if (Cwd::abs_path($self->get_conf('BUILD_DIR')) eq Cwd::abs_path(dirname($filename))) {
		    $symlinktarget = basename($filename)
		}
		my $symlinkname = $self->get_conf('BUILD_DIR') . '/';
		# we might not know the pkgname_ver string if the user only specified a
		# package name without version
		if ($self->get('Package_SVersion')) {
		    $symlinkname .= $self->get('Package_SVersion');
		} else {
		    $symlinkname .= $self->get('Package');
		}
		$symlinkname .= '_' . $self->get('Host Arch') . ".build";
		$self->log_symlink($symlinktarget, $symlinkname);
	    }
	}

	# Cache vars to avoid repeated hash lookups.
	my $nolog = $self->get_conf('NOLOG');
	my $log = $self->get_conf('LOG_DIR_AVAILABLE');
	my $verbose = $self->get_conf('VERBOSE');
	my $log_colour = $self->get_conf('LOG_COLOUR');
	my @filter = ();
	my @colour = ();
	my ($text, $replacement);
	my $filter_regex = "^$filter_prefix(.*):(.*)\$";
	my $colour_regex = "^$colour_prefix(.*):(.*)\$";
	my @ignore = ();

	while (<STDIN>) {
	    # Add a replacement pattern to filter (sent from main
	    # process in log stream).
	    if (m/$filter_regex/) {
		($text,$replacement)=($1,$2);
		$replacement = "<<$replacement>>";
		push (@filter, [$text, $replacement]);
		$_ = "I: NOTICE: Log filtering will replace '$text' with '$replacement'\n";
	    } elsif (m/$colour_regex/) {
		my ($colour, $regex);
		($colour,$regex)=($1,$2);
		push (@colour, [$colour, $regex]);
#		$_ = "I: NOTICE: Log colouring will colour '$regex' in $colour\n";
		next;
	    } else {
		# Filter out any matching patterns
		foreach my $pattern (@filter) {
		    ($text,$replacement) = @{$pattern};
		    s/\Q$text\E/$replacement/g;
		}
	    }
	    if (m/Deprecated key/ || m/please update your configuration/) {
		my $skip = 0;
		foreach my $ignore (@ignore) {
		    $skip = 1 if ($ignore eq $_);
		}
		next if $skip;
		push(@ignore, $_);
	    }

	    if ($nolog || $verbose) {
		my $colour = 'reset';
		if (-t $saved_stdout && $log_colour) {
		    foreach my $pattern (@colour) {
			if (m/$$pattern[0]/) {
			    $colour = $$pattern[1];
			}
		    }
		    if ($colour ne 'reset') {
			print $saved_stdout color $colour;
		    }
		}

		print $saved_stdout $_;
		if (-t $saved_stdout && $log_colour && $colour ne 'reset') {
		    print $saved_stdout color 'reset';
		}
	    }
	    if (!$nolog && $log) {
		    print CPLOG $_;
	    }
	}

	close CPLOG;
	exit 0;
    }

    $PLOG->autoflush(1);
    open(STDOUT, '>&', $PLOG) or warn "Can't redirect stdout\n";
    open(STDERR, '>&', $PLOG) or warn "Can't redirect stderr\n";
    $self->set('Log File', $filename);
    $self->set('Log Stream', $PLOG);

    my $hostname = $self->get_conf('HOSTNAME');
    $self->log("sbuild (Debian sbuild) $version ($release_date) on $hostname\n");

    my $arch_string = $self->get('Host Arch');
    my $head1 = $self->get('Package');
    if ($self->get('Version')) {
	$head1 .= ' ' . $self->get('Version');
    }
    $head1 .= ' (' . $arch_string . ') ';
    my $head2 = strftime_c "%a, %d %b %Y %H:%M:%S +0000",
			 gmtime($self->get('Pkg Start Time'));
    my $head = $head1;
    # If necessary, insert spaces so that $head1 is left aligned and $head2 is
    # right aligned. If the sum of the length of both is greater than the
    # available space of 76 characters, then no additional padding is
    # inserted.
    if (length($head1) + length($head2) <= 76) {
	$head .= ' ' x (76 - length($head1) - length($head2));
    }
    $head .= $head2;
    $self->log_section($head);

    $self->log("Package: " . $self->get('Package') . "\n");
    if (defined $self->get('Version')) {
	$self->log("Version: " . $self->get('Version') . "\n");
    }
    if (defined $self->get('OVersion')) {
	$self->log("Source Version: " . $self->get('OVersion') . "\n");
    }
    $self->log("Distribution: " . $self->get_conf('DISTRIBUTION') . "\n");
    $self->log("Machine Architecture: " . $self->get_conf('ARCH') . "\n");
    $self->log("Host Architecture: " . $self->get('Host Arch') . "\n");
    $self->log("Build Architecture: " . $self->get('Build Arch') . "\n");
    $self->log("Build Profiles: " . $self->get('Build Profiles') . "\n") if $self->get('Build Profiles');
    $self->log("Build Type: " . $self->get('Build Type') . "\n");
    $self->log("\n");
}

sub close_build_log {
    my $self = shift;

    my $time = $self->get('Pkg End Time');
    if ($time == 0) {
        $time = time;
    }
    my $date = strftime_c "%FT%TZ", gmtime($time);

    my $hours = int($self->get('This Time')/3600);
    my $minutes = int(($self->get('This Time')%3600)/60),
    my $seconds = int($self->get('This Time')%60),
    my $space = "no";
    if ($self->get('This Space') >= 0) {
	$space = sprintf("%dk", $self->get('This Space'));
    }

    my $filename = $self->get('Log File');

    # building status at this point means failure.
    if ($self->get_status() eq "building") {
	$self->set_status('failed');
    }

    $self->log_subsection('Summary');
    $self->generate_stats();
    $self->log_stats();

    $self->log_sep();
    $self->log("Finished at ${date}\n");
    $self->log(sprintf("Build needed %02d:%02d:%02d, %s disk space\n",
	       $hours, $minutes, $seconds, $space));

    if ($self->get_status() eq "successful") {
	if (length $self->get_conf('KEY_ID')) {
	    my $key_id = $self->get_conf('KEY_ID');
	    my $build_dir = $self->get_conf('BUILD_DIR');
	    my $changes;
	    $self->log(sprintf("Signature with key '%s' requested:\n", $key_id));
	    $changes = $self->get_changes();
	    if (!defined($changes)) {
		$self->log_error(".changes is undef. Cannot sign .changes.\n");
	    } else {
		system('debsign', '--re-sign', "-k$key_id", '--', "$build_dir/$changes");
	    }
	    if ($self->get_conf('SOURCE_ONLY_CHANGES')) {
		# We would like to run debsign with --no-re-sign so that a file
		# referenced by the normal changes file and was already signed
		# there does not get changed here by re-signing. Otherwise, the
		# checksum from the normal changes file might not match
		# anymore. https://bugs.debian.org/977674
		#
		# The problem is, that with --no-re-sign, debsign will see a
		# signed buildinfo file and skip signing the dsc.
		# https://bugs.debian.org/981021
		my $so_changes = $build_dir . '/' . $self->get('Package_SVersion') . "_source.changes";
		if (-r $so_changes) {
		    system('debsign', '--re-sign', "-k$key_id", '--', "$so_changes");
		} else {
		    $self->log_error("$so_changes unreadable. Cannot sign .changes.\n");
		}
	    }
	}
    }

    my $subject = "Log for " . $self->get_status() . " build of ";
    if ($self->get('Package_Version')) {
	$subject .= $self->get('Package_Version');
    } else {
	$subject .= $self->get('Package');
    }

    if ($self->get_conf('BUILD_SOURCE') && !$self->get_conf('BUILD_ARCH_ALL') && !$self->get_conf('BUILD_ARCH_ANY')) {
	$subject .= " source";
    }
    if ($self->get_conf('BUILD_ARCH_ALL') && !$self->get_conf('BUILD_ARCH_ANY')) {
	$subject .= " on all";
    } elsif ($self->get('Host Arch')) {
	$subject .= " on " . $self->get('Host Arch');
    }
    if ($self->get_conf('ARCHIVE')) {
	$subject .= " (" . $self->get_conf('ARCHIVE') . "/" . $self->get_conf('DISTRIBUTION') . ")";
    }
    else {
	    $subject .= " (dist=" . $self->get_conf('DISTRIBUTION') . ")";
    }

    open(STDERR, '>&', $saved_stderr) or warn "Can't redirect stderr\n"
	if defined($saved_stderr);
    open(STDOUT, '>&', $saved_stdout) or warn "Can't redirect stdout\n"
	if defined($saved_stdout);
    $saved_stderr->close();
    undef $saved_stderr;
    $saved_stdout->close();
    undef $saved_stdout;
    $self->set('Log File', undef);
    if (defined($self->get('Log Stream'))) {
	$self->get('Log Stream')->close(); # Close child logger process
	$self->set('Log Stream', undef);
    }

    $self->send_build_log($self->get_conf('MAILTO'), $subject, $filename)
	if (defined($filename) && -f $filename &&
	    $self->get_conf('MAILTO'));
}

sub send_build_log {
    my $self = shift;
    my $to = shift;
    my $subject = shift;
    my $filename = shift;

    my $conf = $self->get('Config');

    if ($conf->get('MIME_BUILD_LOG_MAILS')) {
	return $self->send_mime_build_log($to, $subject, $filename);
    } else {
        return send_mail($conf, $to, $subject, $filename);
    }
}

sub send_mime_build_log {
    my $self = shift;
    my $to = shift;
    my $subject = shift;
    my $filename = shift;

    my $conf = $self->get('Config');
    my $tmp; # Needed for gzip, here for proper scoping.

    my $msg = MIME::Lite->new(
	    From    => $conf->get('MAILFROM'),
	    To      => $to,
	    Subject => $subject,
	    Type    => 'multipart/mixed'
	    );

    # Add the GPG key ID to the mail if present so that it's clear if the log
    # still needs signing or not.
    if (length $self->get_conf('KEY_ID')) {
	$msg->add('Key-ID', $self->get_conf('KEY_ID'));
    }

    if (!$conf->get('COMPRESS_BUILD_LOG_MAILS')) {
	my $log_part = MIME::Lite->new(
		Type     => 'text/plain',
		Path     => $filename,
		Filename => basename($filename)
		);
	$log_part->attr('content-type.charset' => 'UTF-8');
	$msg->attach($log_part);
    } else {
	local( *F, *GZFILE );

	if (!open( F, "<$filename" )) {
	    warn "Cannot open $filename for mailing: $!\n";
	    return 0;
	}

	$tmp = File::Temp->new();
	tie *GZFILE, 'IO::Zlib', $tmp->filename, 'wb';

	while( <F> ) {
	    print GZFILE $_;
	}
	untie *GZFILE;

	close F;
	close GZFILE;

	$msg->attach(
		Type     => 'application/x-gzip',
		Path     => $tmp->filename,
		Filename => basename($filename) . '.gz'
		);
    }
    my $build_dir = $self->get_conf('BUILD_DIR');
    my $changes = $self->get_changes();
    if ($self->get_status() eq 'successful' && -r "$build_dir/$changes") {
	my $log_part = MIME::Lite->new(
		Type     => 'text/plain',
		Path     => "$build_dir/$changes",
		Filename => basename($changes)
		);
	$log_part->attr('content-type.charset' => 'UTF-8');
	$msg->attach($log_part);
    }

    my $stats = '';
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	$stats .= sprintf("%s: %s\n", $stat, $self->get('Summary Stats')->{$stat});
    }
    $msg->attach(
	Type => 'text/plain',
	Filename => basename($filename) . '.summary',
	Data => $stats
	);

    local $SIG{'PIPE'} = 'IGNORE';

    if (!open( MAIL, "|" . $conf->get('MAILPROG') . " -oem $to" )) {
	warn "Could not open pipe to " . $conf->get('MAILPROG') . ": $!\n";
	close( F );
	return 0;
    }

    $msg->print(\*MAIL);

    if (!close( MAIL )) {
	warn $conf->get('MAILPROG') . " failed (exit status $?)\n";
	return 0;
    }
    return 1;
}

sub log_symlink {
    my $self = shift;
    my $log = shift;
    my $dest = shift;

    unlink $dest; # Don't return on failure, since the symlink will fail.
    symlink $log, $dest;
}

sub get_changes_opts {
    my $self = shift;
    my @changes_opts = ();
	foreach (@{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')}) {
	    if (/^--changes-option=(.*)$/) {
		    push @changes_opts, $1;
	    } elsif (/^-s[iad]$/) {
		    push @changes_opts, $_;
	    } elsif (/^--build=.*$/) {
		    push @changes_opts, $_;
	    } elsif (/^-m.*$/) {
		    push @changes_opts, $_;
	    } elsif (/^-e.*$/) {
		    push @changes_opts, $_;
	    } elsif (/^-v.*$/) {
		    push @changes_opts, $_;
	    } elsif (/^-C.*$/) {
		    push @changes_opts, $_;
	    }
	}

    return \@changes_opts;
}

1;
