#
# ConfBase.pm: configuration library (base functionality) for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2008 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ConfBase;

use strict;
use warnings;

use Data::Dumper;

use Sbuild          qw(isin);
use Sbuild::Utility qw(natatime);

BEGIN {
	use Exporter ();
	our (@ISA, @EXPORT);

	@ISA = qw(Exporter);

	@EXPORT = qw();
}

sub init_allowed_keys {
	my $self = shift;

	my $validate_program = sub {
		my $self    = shift;
		my $entry   = shift;
		my $key     = $entry->{'NAME'};
		my $program = $self->get($key);

		die "$key binary is not defined"
		  if !defined($program) || !$program;

		# Emulate execvp behaviour by searching the binary in the PATH.
		my @paths
		  = split(/:/, ($ENV{'PATH'} // "/usr/sbin:/usr/bin:/sbin:/bin"));
		# Also consider the empty path for absolute locations.
		push(@paths, '');
		my $found = 0;
		foreach my $path (@paths) {
			$found = 1 if (-x File::Spec->catfile($path, $program));
		}

		die "$key binary '$program' does not exist or is not executable"
		  if !$found;
	};

	my $validate_directory = sub {
		my $self      = shift;
		my $entry     = shift;
		my $key       = $entry->{'NAME'};
		my $directory = $self->get($key);

		die "$key directory is not defined"
		  if !defined($directory);

		die "$key directory $directory does not exist"
		  if !-d $directory;
	};

	my $set_distribution = sub {
		my $conf  = shift;
		my $entry = shift;
		my $value = shift;
		my $key   = $entry->{'NAME'};
		$conf->_set_value($key, $value);

		$conf->set('MAILTO', $conf->get('MAILTO_HASH')->{$value})
		  if ( $value
			&& $conf->get('DISTRIBUTION')
			&& $conf->get('MAILTO_HASH')
			&& $conf->get('MAILTO_HASH')->{$value});
	};

	my @pwinfo = getpwuid($<);
	die "Can't get passwd entry for uid $<: $!" if (!@pwinfo);
	my $home = $ENV{'HOME'};
	if (!$home) {
		print STDERR
		  "W: HOME not set in environment; falling back to $pwinfo[7]\n";
		$home = $pwinfo[7];
	}
	my $username = $pwinfo[0];
	my $fullname = $pwinfo[6];
	$fullname =~ s/,.*$//;

	chomp(my $hostname = `hostname -f`);

	# Not user-settable.
	chomp(my $native_arch = readpipe("dpkg --print-architecture"));

	my @common_keys = (
		'PATH' => {
			TYPE    => 'STRING',
			VARNAME => 'path',
			GROUP   => 'Build environment',
			DEFAULT =>
"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games",
			HELP        => 'PATH to set when running dpkg-buildpackage.',
			CLI_OPTIONS => ['--use-snapshot']
		},
		'DISTRIBUTION' => {
			TYPE    => 'STRING',
			VARNAME => 'distribution',
			GROUP   => 'Build options',
			DEFAULT => undef,
			SET     => $set_distribution,
			HELP    =>
'Default distribution.  By default, no distribution is defined, and the user must specify it with the -d option.  However, a default may be configured here if desired.  Users must take care not to upload to the wrong distribution when this option is set, for example experimental packages will be built for upload to unstable when this is not what is required. In unshare mode, this setting controls how the chroot tarball is created as rules like $unshare_mmdebstrap_extra_args and $unshare_mmdebstrap_distro_mangle use the value of the distribution and not the chroot name.',
			CLI_OPTIONS => ['-d', '--dist']
		},
		'OVERRIDE_DISTRIBUTION' => {
			TYPE    => 'BOOL',
			GROUP   => '__INTERNAL',
			DEFAULT => 0,
			GET     => sub {
				my $conf  = shift;
				my $entry = shift;

				my $dist = $conf->get('DISTRIBUTION');

				my $overridden = 0;
				$overridden = 1
				  if (defined($dist));

				return $overridden;
			},
			HELP => 'Default distribution has been overridden'
		},
		'MAILPROG' => {
			TYPE    => 'STRING',
			VARNAME => 'mailprog',
			GROUP   => 'Programs',
			CHECK   => sub {
				my $conf  = shift;
				my $entry = shift;
				my $key   = $entry->{'NAME'};

				# Only validate if needed.
				if ($conf->get('MAILTO')) {
					$validate_program->($conf, $entry);
				}
			},
			DEFAULT => '/usr/sbin/sendmail',
			HELP    => 'Program to use to send mail'
		},
	# TODO: Check if defaulted in code assuming undef
	# ARCH is the native (build-system) architecture.  Not used for host/build.
		'ARCH' => {
			TYPE    => 'STRING',
			GROUP   => '__INTERNAL',
			DEFAULT => $native_arch,
			HELP    => 'Build architecture (Arch we are building on).'
		},
		'HOST_ARCH' => {
			TYPE    => 'STRING',
			VARNAME => 'host_arch',
			GROUP   => 'Build options',
			DEFAULT => $native_arch,
		   # the $native_arch is different depending on the machine where
		   # sbuild is built but arch:all packages must not differ depending on
		   # the architecture they are built on, so don't show the default for
		   # example config and man page generation
			IGNORE_DEFAULT => 1,
			HELP           => 'Host architecture (Arch we are building for)',
			CLI_OPTIONS    => ['--arch', '--host']
		},
		'BUILD_ARCH' => {
			TYPE    => 'STRING',
			VARNAME => 'build_arch',
			GROUP   => 'Build options',
			DEFAULT => $native_arch,
		   # the $native_arch is different depending on the machine where
		   # sbuild is built but arch:all packages must not differ depending on
		   # the architecture they are built on, so don't show the default for
		   # example config and man page generation
			IGNORE_DEFAULT => 1,
			HELP           => 'Build architecture (Arch we are building on).',
			CLI_OPTIONS    => ['--arch', '--build']
		},
		'HOSTNAME' => {
			TYPE    => 'STRING',
			GROUP   => '__INTERNAL',
			DEFAULT => $hostname,
			HELP    => 'System hostname.  Should not require setting.'
		},
		'HOME' => {
			TYPE    => 'STRING',
			GROUP   => '__INTERNAL',
			DEFAULT => $home,
			HELP    => 'User\'s home directory.  Should not require setting.'
		},
		'USERNAME' => {
			TYPE    => 'STRING',
			GROUP   => '__INTERNAL',
			DEFAULT => $username,
			HELP    => 'User\'s username.  Should not require setting.'
		},
		'FULLNAME' => {
			TYPE    => 'STRING',
			GROUP   => '__INTERNAL',
			DEFAULT => $fullname,
			HELP    => 'User\'s full name.  Should not require setting.'
		},
		'BUILD_USER' => {
			TYPE           => 'STRING',
			VARNAME        => 'build_user',
			GROUP          => 'Core options',
			DEFAULT        => undef,
			IGNORE_DEFAULT => 1,     # don't write the username into the config
			GET            => sub {
				my $conf  = shift;
				my $entry = shift;

				my $retval = $conf->_get($entry->{'NAME'});

				if (!defined($retval)) {
					if ($conf->get('CHROOT_MODE') eq 'unshare') {
						$retval = "sbuild";
					} else {
						$retval = $username;
					}
				}

				return $retval;
			},
			HELP =>
'Username used for running dpkg-buildpackage. By default the user running sbuild and `sbuild` for the unshare mode is used within the chroot as well but that might allow a process from within the chroot to break out of the chroot by attaching to a process running outside the chroot with eg. gdb and then becoming root inside the chroot through schroot and thus be able to leave the chroot.'
		},
		'VERBOSE' => {
			TYPE    => 'NUMERIC',
			VARNAME => 'verbose',
			GROUP   => 'Logging options',
			DEFAULT => undef,
			GET     => sub {
				my $conf  = shift;
				my $entry = shift;

				my $retval = $conf->_get($entry->{'NAME'});

				# Note that during a build, STDOUT is redirected, so
				# this test will fail.  So set explicitly at start to
				# ensure correctness.
				if (!defined($retval)) {
					$retval = 0;
					$retval = 1 if (-t STDIN && -t STDOUT);
				}

				return $retval;
			},
			HELP => 'Verbose logging level'
		},
		'DEBUG' => {
			TYPE    => 'NUMERIC',
			VARNAME => 'debug',
			GROUP   => 'Logging options',
			DEFAULT => 0,
			HELP    => 'Debug logging level'
		},
	);

	$self->set_allowed_keys(@common_keys);
}

sub new {
	my $class = shift;
	my %opts  = @_;

	my $self = {};
	bless($self, $class);

	$self->{'CHECK'} = 1;
	$self->{'CHECK'} = $opts{'CHECK'} if exists $opts{'CHECK'};

	$self->init_allowed_keys();

	return $self;
}

sub get_keys {
	my $self = shift;

	return @{ $self->{'ORDERED_KEYS'} };
}

sub is_default {
	my $self = shift;
	my $key  = shift;

	return ($self->_get_value($key) == undef);
}

sub _get_property_value {
	my $self     = shift;
	my $key      = shift;
	my $property = shift;

	my $entry = $self->{'KEYS'}->{$key};

	return $entry->{$property};
}

sub _get_value {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'VALUE');
}

sub _get_default {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'DEFAULT');
}

sub _get_type {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'TYPE');
}

sub _get_varname {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'VARNAME');
}

sub _get_group {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'GROUP');
}

sub _get_help {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'HELP');
}

sub _get_example {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'EXAMPLE');
}

sub _get_ignore_default {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'IGNORE_DEFAULT');
}

sub _get_cli_options {
	my $self = shift;
	my $key  = shift;

	return $self->_get_property_value($key, 'CLI_OPTIONS');
}

sub _get {
	my $self = shift;
	my $key  = shift;

	my $value = undef;
	$value = $self->_get_value($key);
	$value = $self->_get_default($key)
	  if (!defined($value));

	return $value;
}

sub get {
	my $self = shift;
	my $key  = shift;

	my $entry = $self->{'KEYS'}->{$key};

	my $value = undef;
	if ($entry) {
		if (defined($entry->{'GET'})) {
			$value = $entry->{'GET'}->($self, $entry);
		} else {
			$value = $self->_get($key);
		}
	}

	return $value;
}

sub _set_property_value {
	my $self     = shift;
	my $key      = shift;
	my $property = shift;
	my $value    = shift;

	my $entry = $self->{'KEYS'}->{$key};

	return $entry->{$property} = $value;
}

sub _set_value {
	my $self  = shift;
	my $key   = shift;
	my $value = shift;

	return $self->_set_property_value($key, 'VALUE', $value);
}

sub _set_default {
	my $self  = shift;
	my $key   = shift;
	my $value = shift;

	return $self->_set_property_value($key, 'DEFAULT', $value);
}

sub set {
	my $self  = shift;
	my $key   = shift;
	my $value = shift;

	# Set global debug level.
	$Sbuild::debug_level = $value
	  if ($key eq 'DEBUG' && defined($value));

	my $entry = $self->{'KEYS'}->{$key};

	if (defined($entry)) {
		if (defined($entry->{'SET'})) {
			$value = $entry->{'SET'}->($self, $entry, $value);
		} else {
			$value = $self->_set_value($key, $value);
		}
		$entry->{'NAME'} = $key;
		return $value;
	} else {
		warn "W: key \"$key\" is not allowed in configuration";
		return undef;
	}
}

sub set_allowed_keys {
	my $self = shift;

	my $it = natatime 2, @_;
	while (my ($key, $val) = $it->()) {
		$val->{'NAME'} = $key;
		$self->{'KEYS'}->{$key} = $val;
		push @{ $self->{'ORDERED_KEYS'} }, $key;
	}
}

sub check {
	my $self = shift;
	my $key  = shift;

	my $entry = $self->{'KEYS'}->{$key};

	if (defined($entry)) {
		if ($self->{'CHECK'} && defined($entry->{'CHECK'})) {
			$entry->{'CHECK'}->($self, $entry);
		}
	}
}

sub warn_deprecated {
	my $oldtype = shift;
	my $oldopt  = shift;
	my $newtype = shift;
	my $newopt  = shift;

	warn "W: Obsolete $oldtype option '$oldopt' used in configuration";
	warn "I: The replacement is $newtype option '$newopt'";
}

sub read ($$$$) {
	my $conf             = shift;
	my $paths            = shift;
	my $deprecated_init  = shift;
	my $deprecated_setup = shift;
	my $custom_setup     = shift;

	foreach my $path (@{$paths}) {
		$path = "'$path'";
	}
	my $pathstring = join(", ", @{$paths});

	my $HOME = $conf->get('HOME');

	# Variables are undefined, so config will default to DEFAULT if unset.

	# Create script to source configuration.
	my $script = "use strict;\nuse warnings;\n";
	my @keys   = $conf->get_keys();
	foreach my $key (@keys) {
		next if $conf->_get_group($key) =~ m/^__/;

		my $varname    = $conf->_get_varname($key);
		my $vardefault = $conf->_get_default($key);
		if (defined $vardefault) {
			$script .= "my " . Data::Dumper->Dump([$vardefault], [$varname]);
		} else {
			$script .= "my \$$varname = undef;\n";
		}
	}

	# For compatibility only.  Non-scalars are deprecated.
	$script .= $deprecated_init
	  if ($deprecated_init);

	$script .= <<END;

foreach ($pathstring) {
	if (-r \$_) {
	my \$e = eval `cat "\$_"`;
	if (!defined(\$e)) {
	    print STDERR "E: \$_: Errors found in configuration file:\n\$\@";
	    exit(1);
	}
    }
}

# Needed before any program validation.
\$conf->set('PATH', \$path);
END

	# Non-scalar values, for backward compatibility.
	$script .= $deprecated_setup
	  if ($deprecated_setup);

	foreach my $key (@keys) {
		next if $conf->_get_group($key) =~ m/^__/;

		my $varname = $conf->_get_varname($key);
		$script .= "\$conf->set('$key', \$$varname);\n";
	}

	foreach my $key (@keys) {
		next if $conf->_get_group($key) =~ m/^__/;

		my $varname = $conf->_get_varname($key);
		$script .= "\$conf->check('$key');\n";
	}

	$script .= $custom_setup
	  if ($custom_setup);

	$script .= "return 1;\n";

	eval $script or die "Error reading configuration: $@";
}

1;
