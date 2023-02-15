#
# Conf.pm: configuration library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2010 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Conf;

use strict;
use warnings;

use Cwd qw(cwd);
use File::Spec;
use POSIX qw(getgroups getgid);
use Sbuild qw(isin);
use Sbuild::ConfBase;
use Sbuild::Sysconfig;
use Dpkg::Build::Info;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(new setup read);
}

sub setup ($);
sub read ($);

sub new {
    my $conf = Sbuild::ConfBase->new(@_);
    Sbuild::Conf::setup($conf);
    Sbuild::Conf::read($conf);

    return $conf;
}

sub setup ($) {
    my $conf = shift;

    my $validate_program = sub {
	my $conf = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $program = $conf->get($key);

	die "$key binary is not defined"
	    if !defined($program) || !$program;

	# Emulate execvp behaviour by searching the binary in the PATH.
	my @paths = split(/:/, $conf->get('PATH'));
	# Also consider the empty path for absolute locations.
	push (@paths, '');
	my $found = 0;
	foreach my $path (@paths) {
	    $found = 1 if (-x File::Spec->catfile($path, $program));
	}

	die "$key binary '$program' does not exist or is not executable"
	    if !$found;
    };

    my $validate_directory = sub {
	my $conf = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $directory = $conf->get($key);

	die "$key directory is not defined"
	    if !defined($directory) || !$directory;

	die "$key directory '$directory' does not exist"
	    if !-d $directory;
    };

    my $validate_append_version = sub {
	my $conf = shift;
	my $entry = shift;

	if (defined($conf->get('APPEND_TO_VERSION')) &&
	    $conf->get('APPEND_TO_VERSION') &&
	    $conf->get('BUILD_SOURCE') != 0) {
	    # See <http://bugs.debian.org/475777> for details
	    die "The --append-to-version option is incompatible with a source upload\n";
	}

	if ($conf->get('BUILD_SOURCE') &&
	    $conf->get('BIN_NMU')) {
	    print STDERR "Not building source package for binNMU\n";
	    $conf->_set_value('BUILD_SOURCE', 0);
	}
    };

    my $set_signing_option = sub {
	my $conf = shift;
	my $entry = shift;
	my $value = shift;
	my $key = $entry->{'NAME'};
	$conf->_set_value($key, $value);

	my @signing_options = ();
	push @signing_options, "-m".$conf->get('MAINTAINER_NAME')
	    if defined $conf->get('MAINTAINER_NAME');
	push @signing_options, "-e".$conf->get('UPLOADER_NAME')
	    if defined $conf->get('UPLOADER_NAME');
	$conf->set('SIGNING_OPTIONS', \@signing_options);
    };

    our $HOME = $conf->get('HOME');

    my %sbuild_keys = (
	'CHROOT'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'chroot',
	    GROUP => 'Chroot options',
	    DEFAULT => undef,
	    HELP => 'Default chroot (defaults to distribution[-arch][-sbuild])',
	    CLI_OPTIONS => ['-c', '--chroot']
	},
	'BUILD_ARCH_ALL'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'build_arch_all',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		if (!defined($retval)) {
		    if ($conf->get('BUILD_ARCH') ne $conf->get('HOST_ARCH')) {
			# default for cross
			$retval = 0;
		    } else {
			# default for native
			$retval = 1;
		    }
		}

		return $retval;
	    },
	    HELP => 'Build architecture: all packages by default.',
	    CLI_OPTIONS => ['--arch-all', '--no-arch-all']
	},
	'BUILD_ARCH_ANY'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'build_arch_any',
	    GROUP => 'Build options',
	    DEFAULT => 1,
	    HELP => 'Build architecture: any packages by default.',
	    CLI_OPTIONS => ['--arch-any', '--no-arch-any']
	},
	'BUILD_PROFILES'        => {
	    TYPE => 'STRING',
	    VARNAME => 'build_profiles',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		if (!defined($retval)) {
		    if ($conf->get('BUILD_ARCH') ne $conf->get('HOST_ARCH')) {
			# default for cross
			$retval = $ENV{'DEB_BUILD_PROFILES'} || 'cross nocheck';
		    } else {
			# default for native
			$retval = $ENV{'DEB_BUILD_PROFILES'} || '';
		    }
		}

		return $retval;
	    },
	    HELP => 'Build profiles. Separated by spaces. Defaults to the value of the DEB_BUILD_PROFILES environment variable when building natively and to the cross and nocheck profiles when cross-building.',
	    CLI_OPTIONS => ['--profiles']
	},
	'NOLOG'					=> {
	    TYPE => 'BOOL',
	    VARNAME => 'nolog',
	    GROUP => 'Logging options',
	    DEFAULT => 0,
	    HELP => 'Disable use of log file',
	    CLI_OPTIONS => ['-n', '--nolog']
	},
	'SUDO'					=> {
	    TYPE => 'STRING',
	    VARNAME => 'sudo',
	    GROUP => 'Programs',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('CHROOT_MODE') eq 'split' ||
		    ($conf->get('CHROOT_MODE') eq 'schroot' &&
		     $conf->get('CHROOT_SPLIT'))) {
		    $validate_program->($conf, $entry);

		    local (%ENV) = %ENV; # make local environment
		    $ENV{'DEBIAN_FRONTEND'} = "noninteractive";
		    $ENV{'APT_CONFIG'} = "test_apt_config";
		    $ENV{'SHELL'} = '/bin/sh';

		    my $sudo = $conf->get('SUDO');
		    chomp( my $test_df = `$sudo sh -c 'echo \$DEBIAN_FRONTEND'` );
		    chomp( my $test_ac = `$sudo sh -c 'echo \$APT_CONFIG'` );
		    chomp( my $test_sh = `$sudo sh -c 'echo \$SHELL'` );

		    if ($test_df ne "noninteractive" ||
			$test_ac ne "test_apt_config" ||
			$test_sh ne '/bin/sh') {
			print STDERR "$sudo is stripping APT_CONFIG, DEBIAN_FRONTEND and/or SHELL from the environment\n";
			print STDERR "'Defaults:" . $conf->get('USERNAME') . " env_keep+=\"APT_CONFIG DEBIAN_FRONTEND SHELL\"' is not set in /etc/sudoers\n";
			die "$sudo is incorrectly configured"
		    }
		}
	    },
	    DEFAULT => 'sudo',
	    HELP => 'Path to sudo binary'
	},
	'SU'					=> {
	    TYPE => 'STRING',
	    VARNAME => 'su',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'su',
	    HELP => 'Path to su binary'
	},
	'SCHROOT'				=> {
	    TYPE => 'STRING',
	    GROUP => '__INTERNAL',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('CHROOT_MODE') eq 'schroot') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'schroot',
	    HELP => 'Path to schroot binary'
	},
	'SCHROOT_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'schroot_options',
	    GROUP => 'Programs',
	    DEFAULT => ['-q'],
	    HELP => 'Additional command-line options for schroot'
	},
	'UNSHARE_TMPDIR_TEMPLATE'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'unshare_tmpdir_template',
	    GROUP => 'Programs',
	    DEFAULT => '/tmp/tmp.sbuild.XXXXXXXXXX',
	    HELP => 'Template used to create the temporary unpack directory for the unshare chroot mode.'
	    # CLI_OPTIONS => ['--unshare-tmpdir-template']
	},
	'UNSHARE_BIND_MOUNTS'			=> {
	    TYPE => 'ARRAY',
	    VARNAME => 'unshare_bind_mounts',
	    GROUP => 'Programs',
	    CHECK =>  sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};
		for my $entry (@{$conf->get($key)}) {
		    die "$entry->{directory} doesn't exist" if ! -e $entry->{directory};
		    die "mountpoint $entry->{mountpoint} must be an absolute path inside the chroot" if $entry->{mountpoint} !~ /^\//;
		}
	    },
	    DEFAULT => [],
	    HELP => 'Bind mount directories from the outside to a mountpoint inside the chroot in unshare mode.',
	    EXAMPLE => '$unshare_bind_mounts = [ { directory => "/home/path/outside", mountpoint => "/path/inside" } ];'
	},
	'AUTOPKGTEST_VIRT_SERVER'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'autopkgtest_virt_server',
	    GROUP => 'Programs',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};
		my $program = $conf->get($key);

		# if the autopkgtest virtualization server name is only letters
		# a-z then it is missing the autopkgtest-virt- prefix
		if ($program =~ /^[a-z]+$/) {
		    $conf->set($key, "autopkgtest-virt-$program");
		}

		# Only validate if needed.
		if ($conf->get('CHROOT_MODE') eq 'autopkgtest') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'autopkgtest-virt-schroot',
	    HELP => 'Path to autopkgtest-virt-* binary, selecting the virtualization server.',
	    CLI_OPTIONS => ['--autopkgtest-virt-server']
	},
	'AUTOPKGTEST_VIRT_SERVER_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'autopkgtest_virt_server_options',
	    GROUP => 'Programs',
	    DEFAULT => [],
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		my $dist = $conf->get('DISTRIBUTION');
		my $hostarch = $conf->get('HOST_ARCH');
		my %percent = (
		    '%' => '%',
		    'a' => $hostarch, 'SBUILD_HOST_ARCH' => $hostarch,
		    'r' => $dist, 'SBUILD_DISTRIBUTION' => $dist,
		);

		my $keyword_pat = join("|",
		    sort {length $b <=> length $a || $a cmp $b} keys %percent);
		foreach (@{$retval}) {
		    s{
			# Match a percent followed by a valid keyword
			\%($keyword_pat)
		    }{
			# Substitute with the appropriate value only if it's defined
			$percent{$1} || $&
		    }msxge;
		}
		return $retval;
	    },
	    HELP => 'Additional command-line options for autopkgtest-virt-*',
	    CLI_OPTIONS => ['--autopkgtest-virt-server-opt', '--autopkgtest-virt-server-opts']
	},
	# Do not check for the existance of fakeroot because it's needed
	# inside the chroot and not on the host
	'FAKEROOT'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'fakeroot',
	    GROUP => 'Programs',
	    DEFAULT => 'fakeroot',
	    HELP => 'Path to fakeroot binary'
	},
	'APT_GET'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'apt_get',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'apt-get',
	    HELP => 'Path to apt-get binary'
	},
	'APT_CACHE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'apt_cache',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'apt-cache',
	    HELP => 'Path to apt-cache binary'
	},
	'APTITUDE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'aptitude',
	    GROUP => 'Programs',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('BUILD_DEP_RESOLVER') eq 'aptitude') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'aptitude',
	    HELP => 'Path to aptitude binary'
	},
	'XAPT'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'xapt',
	    GROUP => 'Programs',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('BUILD_DEP_RESOLVER') eq 'xapt') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'xapt'
	},
	'DPKG_BUILDPACKAGE_USER_OPTIONS'	=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'dpkg_buildpackage_user_options',
	    GROUP => 'Programs',
	    DEFAULT => [],
	    HELP => 'Additional command-line options for dpkg-buildpackage.',
	    CLI_OPTIONS => ['--debbuildopt', '--debbuildopts', '--jobs']
	},
	'DPKG_FILE_SUFFIX'	=> {
	    TYPE => 'STRING',
	    VARNAME => 'dpkg_file_suffix',
	    GROUP => 'Programs',
	    DEFAULT => '',
	    HELP => 'Suffix to add to filename for files generated by dpkg-buildpackage',
	    CLI_OPTIONS => ['--dpkg-file-suffix']
	},
	'DPKG_SOURCE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'dpkg_source',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'dpkg-source',
	    HELP => 'Path to dpkg-source binary'
	},
	'DPKG_SOURCE_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'dpkg_source_opts',
	    GROUP => 'Programs',
	    DEFAULT => [],
	    HELP => 'Additional command-line options for dpkg-source',
	    CLI_OPTIONS => ['--dpkg-source-opt', '--dpkg-source-opts']
	},
	'MD5SUM'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'md5sum',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'md5sum',
	    HELP => 'Path to md5sum binary'
	},
	'STATS_DIR'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'stats_dir',
	    GROUP => 'Statistics',
	    IGNORE_DEFAULT => 1, # Don't dump the current home
	    DEFAULT => "$HOME/stats",
	    HELP => 'Directory for writing build statistics to',
	    CLI_OPTIONS => ['--stats-dir']
	},
	'PACKAGE_CHECKLIST'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'package_checklist',
	    GROUP => 'Chroot options',
	    DEFAULT => "$Sbuild::Sysconfig::paths{'SBUILD_LOCALSTATE_DIR'}/package-checklist",
	    HELP => 'Where to store list currently installed packages inside chroot'
	},
	'BUILD_ENV_CMND'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'build_env_cmnd',
	    GROUP => 'Build options',
	    DEFAULT => "",
	    HELP => 'This command is run with the dpkg-buildpackage command line passed to it (in the chroot, if doing a chrooted build).  It is used by the sparc buildd (which is sparc64) to call the wrapper script that sets the environment to sparc (32-bit).  It could be used for other build environment setup scripts.  Note that this is superseded by schroot\'s \'command-prefix\' option'
	},
	'PGP_OPTIONS'				=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'pgp_options',
	    GROUP => 'Build options',
	    DEFAULT => ['-us', '-uc'],
	    HELP => 'Additional signing options for dpkg-buildpackage'
	},
	'LOG_DIR'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'log_dir',
	    GROUP => 'Logging options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};
		my $directory = $conf->get($key);
	    },
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		# user mode defaults to the build directory, while buildd mode
		# defaults to $HOME/logs.
		if (!defined($retval)) {
		    $retval = $conf->get('BUILD_DIR');
		    if ($conf->get('SBUILD_MODE') eq 'buildd') {
			$retval = "$HOME/logs";
		    }
		}

		return $retval;
	    },
	    HELP => 'Directory for storing build logs.  This defaults to \'.\' when SBUILD_MODE is set to \'user\' (the default), and to \'$HOME/logs\' when SBUILD_MODE is set to \'buildd\'.'
	},
	'LOG_COLOUR'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_colour',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Add colour highlighting to interactive log messages (informational, warning and error messages).  Log files will not be coloured.'
	},
	'LOG_FILTER'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_filter',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Filter variable strings from log messages such as the chroot name and build directory'
	},
	'LOG_DIR_AVAILABLE'			=> {
	    TYPE => 'BOOL',
	    GROUP => '__INTERNAL',
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $nolog = $conf->get('NOLOG');
		my $directory = $conf->get('LOG_DIR');
		my $log_dir_available = 1;

		if ($nolog) {
			$log_dir_available = 0;
		} elsif ($conf->get('SBUILD_MODE') ne "buildd") {
		    if ($directory && ! -d $directory) {
			$log_dir_available = 0;
		    }
		} elsif ($directory && ! -d $directory &&
			 !mkdir $directory) {
		    # Only create the log dir in buildd mode
		    warn "Could not create '$directory': $!\n";
		    $log_dir_available = 0;
		}

		return $log_dir_available;
	    }
	},
	'MAILTO'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'mailto',
	    GROUP => 'Logging options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};
	    },
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		# Now, we might need to adjust the MAILTO based on the
		# config data. We shouldn't do this if it was already
		# explicitly set by the command line option:
		if (defined($conf->get('MAILTO_FORCED_BY_CLI')) &&
		    !$conf->get('MAILTO_FORCED_BY_CLI')
		    && defined($conf->get('DISTRIBUTION'))
		    && $conf->get('DISTRIBUTION')
		    && defined($conf->get('MAILTO_HASH'))
		    && $conf->get('MAILTO_HASH')->{$conf->get('DISTRIBUTION')}) {
		    $retval = $conf->get('MAILTO_HASH')->{$conf->get('DISTRIBUTION')};
		}

		return $retval;
	    },
	    DEFAULT => "",
	    HELP => 'email address to mail build logs to',
	    CLI_OPTIONS => ['--mail-log-to']
	},
	'MAILTO_FORCED_BY_CLI'			=> {
	    TYPE => 'BOOL',
	    GROUP => '__INTERNAL',
	    DEFAULT => 0
	},
	'MAILTO_HASH'				=> {
	    TYPE => 'HASH:STRING',
	    VARNAME => 'mailto_hash',
	    GROUP => 'Logging options',
	    DEFAULT => {},
	    HELP => 'Like MAILTO, but per-distribution.  This is a hashref mapping distribution name to MAILTO.  Note that for backward compatibility, this is also settable using the hash %mailto (deprecated), rather than a hash reference.'
	},
	'MAILFROM'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'mailfrom',
	    GROUP => 'Logging options',
	    DEFAULT => "Source Builder <sbuild>",
	    HELP => 'email address set in the From line of build logs',
	    CLI_OPTIONS => ['--mailfrom']
	},
	'COMPRESS_BUILD_LOG_MAILS'              => {
	    TYPE => 'BOOL',
	    VARNAME => 'compress_build_log_mails',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Should build log mails be compressed?'
	},
	'MIME_BUILD_LOG_MAILS'                  => {
	    TYPE => 'BOOL',
	    VARNAME => 'mime_build_log_mails',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Should build log mails be MIME encoded?'
	},
	'PURGE_BUILD_DEPS'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'purge_build_deps',
	    GROUP => 'Chroot options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $conf->get('PURGE_BUILD_DEPS') . "\'"
		    if !isin($conf->get('PURGE_BUILD_DEPS'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always',
	    HELP => 'When to purge the build dependencies after a build; possible values are "never", "successful", and "always"',
	    CLI_OPTIONS => ['-p', '--purge', '--purge-deps']
	},
	'PURGE_BUILD_DIRECTORY'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'purge_build_directory',
	    GROUP => 'Chroot options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $conf->get('PURGE_BUILD_DIRECTORY') . "\'"
		    if !isin($conf->get('PURGE_BUILD_DIRECTORY'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always',
	    HELP => 'When to purge the build directory after a build; possible values are "never", "successful", and "always"',
	    CLI_OPTIONS => ['-p', '--purge', '--purge-build']
	},
	'PURGE_SESSION'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'purge_session',
	    GROUP => 'Chroot options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $conf->get('PURGE_SESSION') . "\'"
		    if !isin($conf->get('PURGE_SESSION'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always',
	    HELP => 'Purge the schroot session following a build.  This is useful in conjunction with the --purge and --purge-deps options when using snapshot chroots, since by default the snapshot will be deleted. Possible values are "always" (default), "never", and "successful"',
	    CLI_OPTIONS => ['-p', '--purge', '--purge-session']
	},
	'TOOLCHAIN_REGEX'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'toolchain_regex',
	    GROUP => 'Build options',
	    DEFAULT => ['binutils$',
			'dpkg-dev$',
			'gcc-[\d.]+$',
			'g\+\+-[\d.]+$',
			'libstdc\+\+',
			'libc[\d.]+-dev$',
			'linux-kernel-headers$',
			'linux-libc-dev$',
			'gnumach-dev$',
			'hurd-dev$',
			'kfreebsd-kernel-headers$'
		],
	    HELP => 'Regular expressions identifying toolchain packages.  Note that for backward compatibility, this is also settable using the array @toolchain_regex (deprecated), rather than an array reference.'
	},
	'STALLED_PKG_TIMEOUT'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'stalled_pkg_timeout',
	    GROUP => 'Build timeouts',
	    DEFAULT => 150, # minutes
	    HELP => 'Time (in minutes) of inactivity after which a build is terminated. Activity is measured by output to the log file.'
	},
	'MAX_LOCK_TRYS'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'max_lock_trys',
	    GROUP => 'Build timeouts',
	    DEFAULT => 120,
	    HELP => 'Number of times to try waiting for a lock.'
	},
	'LOCK_INTERVAL'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'lock_interval',
	    GROUP => 'Build timeouts',
	    DEFAULT => 5,
	    HELP => 'Lock wait interval (seconds).  Maximum wait time is (max_lock_trys x lock_interval).'
	},
	'CHROOT_MODE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'chroot_mode',
	    GROUP => 'Chroot options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad chroot mode \'" . $conf->get('CHROOT_MODE') . "\'"
		    if !isin($conf->get('CHROOT_MODE'),
			     qw(schroot sudo autopkgtest unshare));
	    },
	    DEFAULT => 'schroot',
	    HELP => 'Mechanism to use for chroot virtualisation.  Possible value are "schroot" (default), "sudo", "autopkgtest" and "unshare".',
	    CLI_OPTIONS => ['--chroot-mode']
	},
	'CHROOT_SPLIT'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'chroot_split',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'Run in split mode?  In split mode, apt-get and dpkg are run on the host system, rather than inside the chroot.'
	},
	'CHECK_SPACE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'check_space',
	    GROUP => 'Build options',
	    DEFAULT => 1,
	    HELP => 'Check free disk space prior to starting a build.  sbuild requires the free space to be at least twice the size of the unpacked sources to allow a build to proceed.  Can be disabled to allow building if space is very limited, but the threshold to abort a build has been exceeded despite there being sufficient space for the build to complete.'
	},
	'BUILD_DIR'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'build_dir',
	    GROUP => 'Core options',
	    DEFAULT => cwd(),
	    IGNORE_DEFAULT => 1, # Don't dump class to config
	    EXAMPLE => '$build_dir = \'/home/pete/build\';',
	    CHECK => $validate_directory,
	    HELP => 'Output directory for build artifacts created by dpkg-buildpackage and the log file. Defaults to the current directory if unspecified. It is used as the location of chroot symlinks (obsolete) and for current build log symlinks and some build logs.  There is no default; if unset, it defaults to the current working directory.  $HOME/build is another common configuration.',
	    CLI_OPTIONS => ['--build-dir']
	},
	'BUILD_PATH'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'build_path',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    HELP => 'By default the package is built in a path of the following format /build/packagename-XXXXXX/packagename-version/ where XXXXXX is a random ascii string. This option allows one to specify a custom path where the package is built inside the chroot. The sbuild user in the chroot must have permissions to create the path. Common writable locations are subdirectories of /tmp or /build. Using /tmp might be dangerous, because (depending on the chroot backend) the /tmp inside the chroot might be a world writable location that can be accessed by processes outside the chroot. The directory /build can only be accessed by the sbuild user and group and should be a safe location. The buildpath must be an empty directory because the last component of the path will be removed after the build is finished. Notice that depending on the chroot backend (see CHROOT_MODE), some locations inside the chroot might be bind mounts that are shared with other sbuild instances. You must avoid using these shared locations as the build path or otherwise concurrent runs of sbuild will likely fail. With the default schroot chroot backend, the directory /build is shared between multiple schroot sessions. You can change this behaviour in /etc/schroot/sbuild/fstab. The behaviour of other chroot backends will vary.',
	    CLI_OPTIONS => ['--build-path']
	},
	'DSC_DIR'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'dsc_dir',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    HELP => 'By default the package is built in a path of the following format /build/packagename-XXXXXX/packagename-version/ where packagename-version are replaced by the values in debian/changelog. This option allows one to specify a custom packagename-version path where the package is built inside the chroot. This is useful to specify a static path for different versions for example for ccache.',
	    CLI_OPTIONS => ['--dsc-dir']
	},
	'SBUILD_MODE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'sbuild_mode',
	    GROUP => 'Core options',
	    DEFAULT => 'user',
	    HELP => 'sbuild behaviour; possible values are "user" (exit status reports build failures) and "buildd" (exit status does not report build failures) for use in a buildd setup.  "buildd" also currently implies enabling of "legacy features" such as chroot symlinks in the build directory and the creation of current symlinks in the build directory.',
	    CLI_OPTIONS => ['--sbuild-mode']
	},
	'CHROOT_SETUP_SCRIPT'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'chroot_setup_script',
	    GROUP => 'Chroot options',
	    DEFAULT => undef,
	    HELP => 'Script to run to perform custom setup tasks in the chroot.',
	    CLI_OPTIONS => ['--setup-hook']
	},
	'FORCE_ORIG_SOURCE'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'force_orig_source',
	    GROUP => 'Build options',
	    DEFAULT => 0,
	    HELP => 'By default, the -s option only includes the .orig.tar.gz when needed (i.e. when the Debian revision is 0 or 1).  By setting this option to 1, the .orig.tar.gz will always be included when -s is used.',
	    CLI_OPTIONS => ['--force-orig-source']
	},
	'INDIVIDUAL_STALLED_PKG_TIMEOUT'	=> {
	    TYPE => 'HASH:NUMERIC',
	    VARNAME => 'individual_stalled_pkg_timeout',
	    GROUP => 'Build timeouts',
	    DEFAULT => {},
	    HELP => 'Some packages may exceed the general timeout (e.g. redirecting output to a file) and need a different timeout.  This has is a mapping between source package name and timeout.  Note that for backward compatibility, this is also settable using the hash %individual_stalled_pkg_timeout (deprecated) , rather than a hash reference.',
	    EXAMPLE =>
'$individual_stalled_pkg_timeout->{\'llvm-toolchain-3.8\'} = 300;
$individual_stalled_pkg_timeout->{\'kicad-packages3d\'} = 90;'
	},
	'ENVIRONMENT_FILTER'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'environment_filter',
	    GROUP => 'Core options',
	    DEFAULT => [ sort (map "^$_\$", Dpkg::BuildInfo::get_build_env_allowed()) ],
#	    GET => sub {
#		my $conf = shift;
#		my $entry = shift;
#
#		my $retval = $conf->_get($entry->{'NAME'});
#
#		if (!defined($retval)) {
#		    $retval = [ map "^$_\$", Dpkg::BuildInfo::get_build_env_allowed() ];
#		}
#
#		return $retval;
#	    },
	    HELP => 'Only environment variables matching one of the regular expressions in this arrayref will be passed to dpkg-buildpackage and other programs run by sbuild. The default value for this configuration setting is the list of variable names as returned by Dpkg::BuildInfo::get_build_env_allowed() which is also the list of variable names that is whitelisted to be recorded in .buildinfo files. Caution: the default value listed below was retrieved from the dpkg Perl library version available when this man page was generated. It might be different if your dpkg Perl library version differs.',
	    EXAMPLE =>
'# Setting the old environment filter
$environment_filter = [\'^PATH$\',
			\'^DEB(IAN|SIGN)?_[A-Z_]+$\',
			\'^(C(PP|XX)?|LD|F)FLAGS(_APPEND)?$\',
			\'^USER(NAME)?$\',
			\'^LOGNAME$\',
			\'^HOME$\',
			\'^TERM$\',
			\'^SHELL$\'];
# Appending FOOBAR to the default
use Dpkg::Build::Info;
$environment_filter = [Dpkg::BuildInfo::get_build_env_allowed(), \'FOOBAR\'];
# Removing FOOBAR from the default
use Dpkg::Build::Info;
$environment_filter = [map /^FOOBAR$/ ? () : $_, Dpkg::BuildInfo::get_build_env_allowed()];
'
	},
	'BUILD_ENVIRONMENT'			=> {
	    TYPE => 'HASH:STRING',
	    VARNAME => 'build_environment',
	    GROUP => 'Core options',
	    DEFAULT => {},
	    HELP => 'Environment to set during the build.  Defaults to setting PATH and LD_LIBRARY_PATH only.  Note that these environment variables are not subject to filtering with ENVIRONMENT_FILTER.  Example:',
	    EXAMPLE =>
'$build_environment = {
        \'CCACHE_DIR\' => \'/build/cache\'
};'
	},
	'LD_LIBRARY_PATH'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'ld_library_path',
	    GROUP => 'Build environment',
	    DEFAULT => undef,
	    HELP => 'Library search path to use inside the chroot.',
	    CLI_OPTIONS => ['--use-snapshot']
	},
	'MAINTAINER_NAME'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'maintainer_name',
	    GROUP => 'Maintainer options',
	    DEFAULT => undef,
	    SET => $set_signing_option,
	    HELP => 'Name to use as override in .changes files for the Maintainer field.  The Maintainer field will not be overridden unless set here.',
	    CLI_OPTIONS => ['-m', '--maintainer']
	},
	'UPLOADER_NAME'				=> {
	    VARNAME => 'uploader_name',
	    TYPE => 'STRING',
	    GROUP => 'Maintainer options',
	    DEFAULT => undef,
	    SET => $set_signing_option,
	    HELP => 'Name to use as override in .changes file for the Changed-By: field.',
	    CLI_OPTIONS => ['-e', '--uploader']
	},
	'KEY_ID'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'key_id',
	    GROUP => 'Maintainer options',
	    DEFAULT => undef,
	    HELP => 'Key ID to use in .changes for the current upload.  It overrides both $maintainer_name and $uploader_name.',
	    CLI_OPTIONS => ['-k', '--keyid']
	},
	'SIGNING_OPTIONS'			=> {
	    TYPE => 'STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => "",
	    HELP => 'PGP-related identity options to pass to dpkg-buildpackage. Usually neither .dsc nor .changes files are not signed automatically.'
	},
	'APT_CLEAN'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_clean',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'APT clean.  1 to enable running "apt-get clean" at the start of each build, or 0 to disable.',
	    CLI_OPTIONS => ['--apt-clean', '--no-apt-clean']
	},
	'APT_KEEP_DOWNLOADED_PACKAGES'          => {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_keep_downloaded_packages',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'Keep downloaded packages in cache by APT. Controls APT::Keep-Downloaded-Packages option used when downloading dependencies. This option only makes sense if /var/cache/apt/archive inside the chroot is made persistent between multiple sbuild invocations. 1 to keep downloaded packages in cache, or 0 to delete them after installation.'
	},
	'APT_UPDATE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_update',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'APT update.  1 to enable running "apt-get update" at the start of each build, or 0 to disable. This option has no effect on updating the internal sbuild apt repository, the repository for extra packages (see EXTRA_PACKAGES) and the repositories given via EXTRA_REPOSITORIES. These are always updated. Thus, this option only influences updates of the default repositories of the chroot.',
	    CLI_OPTIONS => ['--apt-update', '--no-apt-update']
	},
	'APT_UPDATE_ARCHIVE_ONLY'		=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_update_archive_only',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'Update local temporary APT archive directly (1, the default) or set to 0 to disable and do a full apt update (not recommended in case the mirror content has changed since the build started).'
	},
	'APT_UPGRADE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_upgrade',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'APT upgrade.  1 to enable running "apt-get upgrade" at the start of each build, or 0 to disable.',
	    CLI_OPTIONS => ['--apt-upgrade', '--no-apt-upgrade']
	},
	'APT_DISTUPGRADE'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_distupgrade',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'APT distupgrade.  1 to enable running "apt-get dist-upgrade" at the start of each build, or 0 to disable.',
	    CLI_OPTIONS => ['--apt-distupgrade', '--no-apt-distupgrade']
	},
	'APT_ALLOW_UNAUTHENTICATED'		=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_allow_unauthenticated',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'Force APT to accept unauthenticated packages.  By default, unauthenticated packages are not allowed.  This is to keep the build environment secure, using apt-secure(8).  By setting this to 1, APT::Get::AllowUnauthenticated is set to "true" when running apt-get. This is disabled by default: only enable it if you know what you are doing.'
	},
	'BATCH_MODE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'batch_mode',
	    GROUP => 'Core options',
	    DEFAULT => 0,
	    HELP => 'Enable batch mode?',
	    CLI_OPTIONS => ['-b', '--batch']
	},
	'CORE_DEPENDS'				=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'core_depends',
	    GROUP => 'Core options',
	    DEFAULT => ['build-essential:native', 'fakeroot:native'],
	    HELP => 'Packages which must be installed in the chroot for all builds.'
	},
	'MANUAL_DEPENDS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'manual_depends',
	    GROUP => 'Core options',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.',
	    CLI_OPTIONS => ['--add-depends']
	},
	'MANUAL_CONFLICTS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'manual_conflicts',
	    GROUP => 'Core options',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.',
	    CLI_OPTIONS => ['--add-conflicts']
	},
	'MANUAL_DEPENDS_ARCH'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'manual_depends_arch',
	    GROUP => 'Core options',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.',
	    CLI_OPTIONS => ['--add-depends-arch']
	},
	'MANUAL_CONFLICTS_ARCH'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'manual_conflicts_arch',
	    GROUP => 'Core options',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.',
	    CLI_OPTIONS => ['--add-conflicts-arch']
	},
	'MANUAL_DEPENDS_INDEP'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'manual_depends_indep',
	    GROUP => 'Core options',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.',
	    CLI_OPTIONS => ['--add-depends-indep']
	},
	'MANUAL_CONFLICTS_INDEP'		=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'manual_conflicts_indep',
	    GROUP => 'Core options',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.',
	    CLI_OPTIONS => ['--add-conflicts-indep']
	},
	'CROSSBUILD_CORE_DEPENDS'				=> {
	    TYPE => 'HASH:ARRAY:STRING',
	    VARNAME => 'crossbuild_core_depends',
	    GROUP => 'Multiarch support (transitional)',
	    DEFAULT => {},
	    HELP => 'Per-architecture dependencies required for cross-building. By default, if a Debian architecture is not found as a key in this hash, the following will be added to the Build-Depends: crossbuild-essential-${hostarch}:native, libc-dev, libstdc++-dev. The latter two are to work around bug #815172.',
	    EXAMPLE => '
$crossbuild_core_depends = {
    nios2 => [\'crossbuild-essential-nios2:native\', \'special-package\'],
    musl-linux-mips => [\'crossbuild-essential-musl-linux-mips:native\', \'super-special\'],
}
'
	},	'BUILD_SOURCE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'build_source',
	    GROUP => 'Build options',
	    DEFAULT => 0,
	    CHECK => $validate_append_version,
	    HELP => 'By default, do not build a source package (binary only build).  Set to 1 to force creation of a source package, but note that this is inappropriate for binary NMUs, where the option will always be disabled.',
	    CLI_OPTIONS => ['-s', '--source', '--no-source']
	},
	'ARCHIVE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'archive',
	    GROUP => 'Core options',
	    DEFAULT => undef,
	    HELP => 'Archive being built.  Only set in build log.  This might be useful for derivative distributions.',
	    CLI_OPTIONS => ['--archive']
	},
	'BIN_NMU'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'bin_nmu',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    CHECK => $validate_append_version,
	    HELP => 'Binary NMU changelog entry.',
	    CLI_OPTIONS => ['--make-binNMU']
	},
	'BIN_NMU_VERSION'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'bin_nmu_version',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    HELP => 'Binary NMU version number.',
	    CLI_OPTIONS => ['--binNMU', '--make-binNMU']
	},
	'BIN_NMU_TIMESTAMP'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'bin_nmu_timestamp',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    HELP => 'Binary NMU timestamp. The timestamp is either given as n integer in Unix time or as a string in the format compatible with Debian changelog entries (i.e. as it is generated by date -R). If set to the default (undef) the date at build time is used.',
	    CLI_OPTIONS => ['--binNMU-timestamp']
	},
	'APPEND_TO_VERSION'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'append_to_version',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    CHECK => $validate_append_version,
	    HELP => 'Suffix to append to version number.  May be useful for derivative distributions.',
	    CLI_OPTIONS => ['--append-to-version']
	},
	'BIN_NMU_CHANGELOG'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'bin_nmu_changelog',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    HELP => 'The content of a binary-only changelog entry. Leading and trailing newlines will be stripped.',
	    CLI_OPTIONS => ['--binNMU-changelog']
	},
	'GCC_SNAPSHOT'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'gcc_snapshot',
	    GROUP => 'Build options',
	    DEFAULT => 0,
	    HELP => 'Build using current GCC snapshot?',
	    CLI_OPTIONS => ['--use-snapshot']
	},
	'JOB_FILE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'job_file',
	    GROUP => 'Core options',
	    DEFAULT => 'build-progress',
	    HELP => 'Job status file (only used in batch mode)'
	},
	'BUILD_DEP_RESOLVER'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'build_dep_resolver',
	    GROUP => 'Dependency resolution',
	    DEFAULT => 'apt',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		if ($conf->get($key) eq 'internal') {
		    warn "W: Build dependency resolver 'internal' has been removed; defaulting to 'apt'.  Please update your configuration.\n";
		    $conf->set('BUILD_DEP_RESOLVER', 'apt');
		}

		die '$key: Invalid build-dependency resolver \'' .
		    $conf->get($key) .
		    "'\nValid algorithms are 'apt', 'aptitude', 'aspcud', 'xapt', and 'null'\n"
		    if !isin($conf->get($key),
			     qw(apt aptitude aspcud xapt null));
	    },
	    HELP => 'Build dependency resolver.  The \'apt\' resolver is currently the default, and recommended for most users.  This resolver uses apt-get to resolve dependencies.  Alternative resolvers are \'apt\', \'aptitude\' and \'aspcud\'. The \'apt\' resolver uses a built-in resolver module while the \'aptitude\' resolver uses aptitude to resolve build dependencies.  The aptitude resolver is similar to apt, but is useful in more complex situations, such as where multiple distributions are required, for example when building from experimental, where packages are needed from both unstable and experimental, but defaulting to unstable. If the dependency situation is too complex for either apt or aptitude to solve it, you can use the \'aspcud\' resolver which (in contrast to apt and aptitude) is a real solver (in the math sense) and will thus always find a solution if a solution exists. Additionally, the \'null\' solver is provided. It is a dummy resolver which does not install, upgrade or remove any packages. This allows one to completely control package installation via hooks.',
	    CLI_OPTIONS => ['--build-dep-resolver']
	},
	'ASPCUD_CRITERIA'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'aspcud_criteria',
	    GROUP => 'Dependency resolution',
	    DEFAULT => '-removed,-changed,-new',
	    HELP => 'Optimization criteria in extended MISC 2012 syntax passed to aspcud through apt-cudf.  Optimization criteria are separated by commas, sorted by decreasing order of priority and are prefixed with a polarity (+ to maximize and - to minimize).  The default criteria is \'-removed,-changed,-new\' which first minimizes the number of removed packages, then the number of changed packages (up or downgrades) and then the number of new packages. A common task is to minimize the number of packages from experimental.  To do this you can add a criteria like \'-count(solution,APT-Release:=/a=experimental/)\' to the default criteria.  This will then minimize the number of packages in the solution which contain the string \'a=experimental\' in the \'APT-Release\' field of the EDSP output created by apt. See the apt-cudf man page help on the --criteria option for more information.',
	    CLI_OPTIONS => ['--aspcud-criteria']
	},
	'CLEAN_SOURCE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'clean_source',
	    GROUP => 'Build options',
	    DEFAULT => 1,
	    HELP => 'When running sbuild from within an unpacked source tree, run the \'clean\' target before generating the source package. This might require some of the build dependencies necessary for running the \'clean\' target to be installed on the host machine. Only disable if you start from a clean checkout and you know what you are doing.',
	    CLI_OPTIONS => ['--clean-source', '--no-clean-source']
	},
	'LINTIAN'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'lintian',
	    GROUP => 'Build validation',
	    DEFAULT => 'lintian',
	    HELP => 'Path to lintian binary'
	},
	'RUN_LINTIAN'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'run_lintian',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		$conf->check('LINTIAN');
	    },
	    DEFAULT => 1,
	    HELP => 'Run lintian?',
	    CLI_OPTIONS => ['--run-lintian', '--no-run-lintian']
	},
	'LINTIAN_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'lintian_opts',
	    GROUP => 'Build validation',
	    DEFAULT => [],
	    HELP => 'Options to pass to lintian.  Each option is a separate arrayref element.  For example, [\'-i\', \'-v\'] to add -i and -v.',
	    CLI_OPTIONS => ['--lintian-opt', '--lintian-opts']
	},
	'LINTIAN_REQUIRE_SUCCESS'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'lintian_require_success',
	    GROUP => 'Build validation',
	    DEFAULT => 0,
	    HELP => 'Let sbuild fail if lintian fails.'
	},
	'PIUPARTS'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'piuparts',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('RUN_PIUPARTS')) {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'piuparts',
	    HELP => 'Path to piuparts binary',
	    CLI_OPTIONS => ['--piuparts-opt', '--piuparts-opts']
	},
	'RUN_PIUPARTS'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'run_piuparts',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		$conf->check('PIUPARTS');
	    },
	    DEFAULT => 0,
	    HELP => 'Run piuparts',
	    CLI_OPTIONS => ['--run-piuparts', '--no-run-piuparts']
	},
	'PIUPARTS_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'piuparts_opts',
	    GROUP => 'Build validation',
	    DEFAULT => [],
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		my $dist = $conf->get('DISTRIBUTION');
		my $hostarch = $conf->get('HOST_ARCH');
		my %percent = (
		    '%' => '%',
		    'a' => $hostarch, 'SBUILD_HOST_ARCH' => $hostarch,
		    'r' => $dist, 'SBUILD_DISTRIBUTION' => $dist,
		);

		my $keyword_pat = join("|",
		    sort {length $b <=> length $a || $a cmp $b} keys %percent);
		foreach (@{$retval}) {
		    s{
			# Match a percent followed by a valid keyword
			\%($keyword_pat)
		    }{
			# Substitute with the appropriate value only if it's defined
			$percent{$1} || $&
		    }msxge;
		}
		return $retval;
	    },
	    HELP => 'Options to pass to piuparts.  Each option is a separate arrayref element.  For example, [\'-b\', \'<chroot_tarball>\'] to add -b and <chroot_tarball>.'
	},
	'PIUPARTS_ROOT_ARGS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'piuparts_root_args',
	    GROUP => 'Build validation',
	    DEFAULT => [],
	    HELP => 'Preceding arguments to launch piuparts as root. With the default value (the empty array) "sudo --" will be used as a prefix. If the first element in the array is the empty string, no prefixing will be done. If the value is a scalar, it will be prefixed by that string. If the scalar is an empty string, no prefixing will be done.',
	    EXAMPLE =>
'# prefix with "sudo --":
$piuparts_root_args = [];
$piuparts_root_args = [\'sudo\', \'--\'];
# prefix with "env":
$piuparts_root_args = [\'env\'];
$piuparts_root_args = \'env\';
# prefix with nothing:
$piuparts_root_args = \'\';
$piuparts_root_args = [\'\'];
$piuparts_root_args = [\'\', \'whatever\'];
',
	    CLI_OPTIONS => ['--piuparts-root-arg', '--piuparts-root-args']
	},
	'PIUPARTS_REQUIRE_SUCCESS'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'piuparts_require_success',
	    GROUP => 'Build validation',
	    DEFAULT => 0,
	    HELP => 'Let sbuild fail if piuparts fails.'
	},
	'AUTOPKGTEST'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'autopkgtest',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('RUN_AUTOPKGTEST')) {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'autopkgtest',
	    HELP => 'Path to autopkgtest binary',
	    CLI_OPTIONS => ['--autopkgtest-opt', '--autopkgtest-opts']
	},
	'RUN_AUTOPKGTEST'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'run_autopkgtest',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		$conf->check('AUTOPKGTEST');
	    },
	    DEFAULT => 0,
	    HELP => 'Run autopkgtest',
	    CLI_OPTIONS => ['--run-autopkgtest', '--no-run-autopkgtest']
	},
	'AUTOPKGTEST_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'autopkgtest_opts',
	    GROUP => 'Build validation',
	    DEFAULT => [],
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		my $dist = $conf->get('DISTRIBUTION');
		my $hostarch = $conf->get('HOST_ARCH');
		my %percent = (
		    '%' => '%',
		    'a' => $hostarch, 'SBUILD_HOST_ARCH' => $hostarch,
		    'r' => $dist, 'SBUILD_DISTRIBUTION' => $dist,
		);

		my $keyword_pat = join("|",
		    sort {length $b <=> length $a || $a cmp $b} keys %percent);
		foreach (@{$retval}) {
		    s{
			# Match a percent followed by a valid keyword
			\%($keyword_pat)
		    }{
			# Substitute with the appropriate value only if it's defined
			$percent{$1} || $&
		    }msxge;
		}
		return $retval;
	    },
	    HELP => 'Options to pass to autopkgtest.  Each option is a separate arrayref element.  For example, [\'-b\', \'<chroot_tarball>\'] to add -b and <chroot_tarball>.'
	},
	'AUTOPKGTEST_ROOT_ARGS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'autopkgtest_root_args',
	    GROUP => 'Build validation',
	    DEFAULT => [],
	    HELP => 'Preceding arguments to launch autopkgtest as root. With the default value (the empty array) "sudo --" will be used as a prefix. If the first element in the array is the empty string, no prefixing will be done. If the value is a scalar, it will be prefixed by that string. If the scalar is an empty string, no prefixing will be done.',
	    EXAMPLE =>
'# prefix with "sudo --":
$autopkgtest_root_args = [];
$autopkgtest_root_args = [\'sudo\', \'--\'];
# prefix with "env":
$autopkgtest_root_args = [\'env\'];
$autopkgtest_root_args = \'env\';
# prefix with nothing:
$autopkgtest_root_args = \'\';
$autopkgtest_root_args = [\'\'];
$autopkgtest_root_args = [\'\', \'whatever\'];
',
	    CLI_OPTIONS => ['--autopkgtest-root-arg', '--autopkgtest-root-args']
	},
	'AUTOPKGTEST_REQUIRE_SUCCESS'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'autopkgtest_require_success',
	    GROUP => 'Build validation',
	    DEFAULT => 0,
	    HELP => 'Let sbuild fail if autopkgtest fails.'
	},
	'EXTERNAL_COMMANDS'			=> {
	    TYPE => 'HASH:ARRAY:STRING',
	    VARNAME => 'external_commands',
	    GROUP => 'Chroot options',
	    DEFAULT => {
		"pre-build-commands" => [],
		"chroot-setup-commands" => [],
		"chroot-update-failed-commands" => [],
		"build-deps-failed-commands" => [],
		"build-failed-commands" => [],
		"starting-build-commands" => [],
		"finished-build-commands" => [],
		"chroot-cleanup-commands" => [],
		"post-build-commands" => [],
	    },
	    HELP => 'External commands to run at various stages of a build. Commands are held in a hash of arrays of arrays data structure. There is no equivalent for the --anything-failed-commands command line option. All percent escapes mentioned in the sbuild man page can be used.',
	    EXAMPLE =>
'# general format
$external_commands = {
    "pre-build-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "chroot-setup-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "chroot-update-failed-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "build-deps-failed-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "build-failed-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "starting-build-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "finished-build-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "chroot-cleanup-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "post-build-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "post-build-failed-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
};
# the equivalent of specifying --anything-failed-commands=%SBUILD_SHELL on the
# command line
$external_commands = {
    "chroot-update-failed-commands" => [ [ \'%SBUILD_SHELL\' ] ],
    "build-deps-failed-commands" => [ [ \'%SBUILD_SHELL\' ] ],
    "build-failed-commands" => [ [ \'%SBUILD_SHELL\' ] ],
};',
	    CLI_OPTIONS => ['--setup-hook', '--pre-build-commands', '--chroot-setup-commands', '--chroot-update-failed-commands', '--build-deps-failed-commands', '--build-failed-commands', '--anything-failed-commands', '--starting-build-commands', '--finished-build-commands', '--chroot-cleanup-commands', '--post-build-commands', '--post-build-failed-commands']
	},
	'LOG_EXTERNAL_COMMAND_OUTPUT'		=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_external_command_output',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'Log standard output of commands run by sbuild?',
	    CLI_OPTIONS => ['--log-external-command-output']
	},
	'LOG_EXTERNAL_COMMAND_ERROR'		=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_external_command_error',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'Log standard error of commands run by sbuild?',
	    CLI_OPTIONS => ['--log-external-command-error']
	},
	'RESOLVE_ALTERNATIVES'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'resolve_alternatives',
	    GROUP => 'Dependency resolution',
	    DEFAULT => undef,
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		if (!defined($retval)) {
		    $retval = 0;
		    $retval = 1
			if ($conf->get('BUILD_DEP_RESOLVER') eq 'aptitude');
		}

		return $retval;
	    },
	    EXAMPLE => '$resolve_alternatives = 0;',
	    HELP => 'Should the dependency resolver use alternatives in Build-Depends, Build-Depends-Arch and Build-Depends-Indep?  By default, using \'apt\' resolver, only the first alternative will be used; all other alternatives will be removed.  When using the \'aptitude\' resolver, it will default to using all alternatives.  Note that this does not include architecture-specific alternatives, which are reduced to the build architecture prior to alternatives removal.  This should be left disabled when building for unstable; it may be useful when building for experimental or backports.  Set to undef to use the default, 1 to enable, or 0 to disable.',
	    CLI_OPTIONS => ['--resolve-alternatives', '--no-resolve-alternatives']
	},
	'EXTRA_PACKAGES'				=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'extra_packages',
	    GROUP => 'Dependency resolution',
	    DEFAULT => [],
	    HELP => 'Additional per-build packages available as build dependencies.',
	    CLI_OPTIONS => ['--extra-package']
	},
	'EXTRA_REPOSITORY_KEYS'				=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'extra_repository_keys',
	    GROUP => 'Dependency resolution',
	    DEFAULT => [],
	    HELP => 'Additional per-build apt repository keys.',
	    CLI_OPTIONS => ['--extra-repository-key']
	},
	'EXTRA_REPOSITORIES'				=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'extra_repositories',
	    GROUP => 'Dependency resolution',
	    DEFAULT => [],
	    HELP => 'Additional per-build apt repositories.',
	    CLI_OPTIONS => ['--extra-repository']
	},
	'SOURCE_ONLY_CHANGES'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'source_only_changes',
	    GROUP => 'Build options',
	    DEFAULT => 0,
	    HELP => 'Also produce a changes file suitable for a source-only upload.',
	    CLI_OPTIONS => ['--source-only-changes']
	},
	'BD_UNINSTALLABLE_EXPLAINER'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'bd_uninstallable_explainer',
	    GROUP => 'Dependency resolution',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad bd-uninstallable explainer \'" . $conf->get('BD_UNINSTALLABLE_EXPLAINER') . "\'"
		    if defined $conf->get('BD_UNINSTALLABLE_EXPLAINER')
		    && !isin($conf->get('BD_UNINSTALLABLE_EXPLAINER'),
			     ('apt', 'dose3', '', 'none'));
	    },
	    DEFAULT => 'dose3',
	    HELP => 'Method to use for explaining build dependency installation failures. Possible value are "dose3" (default), "apt" and "none". Set to "none", the empty string "" or Perl undef to disable running any explainer.',
	    CLI_OPTIONS => ['--bd-uninstallable-explainer']
	},
	'PURGE_EXTRA_PACKAGES'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'purge_extra_packages',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'Try to remove all additional packages that are not strictly required for the build right after build dependencies were installed. This currently works best with the aspcud resolver. The apt resolver will not make as much effort to remove all unneeded packages and will keep all providers of a virtual package and all packages from any dependency alternative that happen to be installed. The aptitude and xapt resolver do not implement this feature yet. The removed packages are not yet added again after the build finished. This can have undesirable side effects like lintian not working (because there is no apt to install its dependencies) or bare chroots becoming totally unusable after apt was removed from them. Thus, this option should only be used with throw-away chroots like schroot provides them where the original state is automatically restored after each build.',
	    CLI_OPTIONS => ['--purge-extra-packages']
	}
    );

    $conf->set_allowed_keys(\%sbuild_keys);
}

sub read ($) {
    my $conf = shift;

    # Set here to allow user to override.
    if (-t STDIN && -t STDOUT) {
	$conf->_set_default('VERBOSE', 1);
    } else {
	$conf->_set_default('VERBOSE', 0);
    }

    my $HOME = $conf->get('HOME');

    my $files = ["$Sbuild::Sysconfig::paths{'SBUILD_CONF'}",
		 "$HOME/.sbuildrc"];

    push @{$files}, $ENV{'SBUILD_CONFIG'} if defined $ENV{'SBUILD_CONFIG'};

    # For compatibility only.  Non-scalars are deprecated.
    my $deprecated_init = <<END;
my \%mailto;
undef \%mailto;
my \@toolchain_regex;
undef \@toolchain_regex;
my \%individual_stalled_pkg_timeout;
undef \%individual_stalled_pkg_timeout;
END

    my $deprecated_setup = <<END;
# Non-scalar values, for backward compatibility.
if (\%mailto) {
    warn 'W: \%mailto is deprecated; please use the hash reference \$mailto{}\n';
    \$conf->set('MAILTO_HASH', \\\%mailto);
}
if (\@toolchain_regex) {
    warn 'W: \@toolchain_regex is deprecated; please use the array reference \$toolchain_regexp[]\n';
    \$conf->set('TOOLCHAIN_REGEX', \\\@toolchain_regex);
}
if (\%individual_stalled_pkg_timeout) {
    warn 'W: \%individual_stalled_pkg_timeout is deprecated; please use the hash reference \$individual_stalled_pkg_timeout{}\n';
    \$conf->set('INDIVIDUAL_STALLED_PKG_TIMEOUT',
		\\\%individual_stalled_pkg_timeout);
}
END

    my $custom_setup = <<END;
push(\@{\${\$conf->get('EXTERNAL_COMMANDS')}{"chroot-user-setup-commands"}},
\$chroot_setup_script) if (\$chroot_setup_script);

    # Trigger log directory creation if needed
    \$conf->get('LOG_DIR_AVAILABLE');

END


    $conf->read($files, $deprecated_init, $deprecated_setup,
		$custom_setup);
}

1;
