#!/usr/bin/perl
#
# sbuild-options-parsing.pl: Check option parsing in Sbuild
# Copyright © 2024 Alexis Murzeau <amubtdx@gmail.com>
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

use strict;
use warnings;

use Test::More;
use File::Spec;
use Data::Dumper;
use FindBin;

# Reset environment to a controlled one
%ENV = (
	'TERM',          'linux',
	'PWD',           '/non-existant-pwd',
	'PATH',          '/sbin:/usr/sbin:/bin:/usr/bin',
	'HOME',          '/non-existant-home',
	'SBUILD_CONFIG', 'test/sbuildrc'
);

# Use lib path instead of system path when importing
# Sbuild modules to be tested.
use lib "$FindBin::Bin/../lib";

use Sbuild::Conf;
use Sbuild::Options;

# Global variable to store an unmodified image of ARGV
my @TESTED_ARGV;

# Run sbuild option parsing
sub run_sbuild_argument_parser {
	my $conf = Sbuild::Conf::new();
	defined($conf) or die "conf is undef";
	my $options = Sbuild::Options->new($conf, "sbuild", "1");
	defined($options) or die "options is undef";

	return $options;
}

# Simulate command line argument and run sbuild option parsing
# then check that the argument was taken into account.
sub check_argument {
	my $argument         = shift;
	my $option_extractor = shift;
	my $value            = shift;

	@ARGV        = ("sbuild", "--${argument}=${value}");
	@TESTED_ARGV = @ARGV;

	my $options = run_sbuild_argument_parser();

	$option_extractor->($options, $value);
}

# Simulate command line argument and run sbuild option parsing
# then check that the argument was taken into account.
# This one check arguments without a value that set a variable to 1 instead.
sub check_bool_argument {
	my $argument         = shift;
	my $option_extractor = shift;

	@ARGV        = ("sbuild", "--${argument}");
	@TESTED_ARGV = @ARGV;

	my $options = run_sbuild_argument_parser();

	$option_extractor->($options, 1);
}

# Returns 1 if the array contains the given value.
sub is_in_array {
	my $array = shift;
	my $value = shift;

	for (@{$array}) {
		if ($_ eq $value) {
			return 1;
		}
	}

	return 0;
}

# Check that an option equal or contains a given value.
sub check_option_value {
	my $result   = shift;
	my $expected = shift;

	if (ref $result eq 'ARRAY') {
		my $array_dump = Dumper($result);
		if (!ok(is_in_array($result, $expected), "check option value")) {
			diag("$expected not in $array_dump");
			diag("command line checked: @TESTED_ARGV");
		}
	} else {
		if (!is($expected, $result)) {
			diag("command line checked: @TESTED_ARGV");
		}
	}
}

# Check that an option contains values in argument.
sub check_option_array_contains {
	my $options         = shift;
	my $options_name    = shift;
	my @values_expected = @_;

	my $result = $options->get_conf($options_name);

	my $array_dump = Dumper($result);
	for my $expected (@values_expected) {
		if (
			!ok(
				is_in_array($result, $expected),
				"check option value $expected"
			)
		) {
			diag("$expected not in $array_dump");
			diag("command line checked: @TESTED_ARGV");
		}
	}
}

sub main {
	# List of arguments to test.
	# This is a hashmap of arguments to a check function.
	# Arguments are in GetOptions format.
	my %command_line_arguments = (
		'arch=s' =>
		  sub { check_option_value($_[0]->get_conf('HOST_ARCH'), $_[1]); },
		'build=s' =>
		  sub { check_option_value($_[0]->get_conf('BUILD_ARCH'), $_[1]); },
		'host=s' =>
		  sub { check_option_value($_[0]->get_conf('HOST_ARCH'), $_[1]); },
		'A|arch-all' =>
		  sub { check_option_value($_[0]->get_conf('BUILD_ARCH_ALL'), $_[1]); }
		,
		'arch-any' =>
		  sub { check_option_value($_[0]->get_conf('BUILD_ARCH_ANY'), $_[1]); }
		,
		'profiles=s' =>
		  sub { check_option_value($_[0]->get_conf('BUILD_PROFILES'), $_[1]); }
		,
		'add-depends=s' =>
		  sub { check_option_value($_[0]->get_conf('MANUAL_DEPENDS'), $_[1]); }
		,
		'add-conflicts=s' => sub {
			check_option_value($_[0]->get_conf('MANUAL_CONFLICTS'), $_[1]);
		},
		# Options using push():
		'j|jobs=i' => sub {
			check_option_value(
				$_[0]->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS'),
				"-j" . $_[1]);
		},
		'setup-hook=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"chroot-setup-commands"},
				$_[1]);
		},
		'pre-build-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"pre-build-commands"},
				$_[1]);
		},
		'chroot-setup-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"chroot-setup-commands"},
				$_[1]);
		},
		'chroot-update-failed-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"chroot-update-failed-commands"},
				$_[1]);
		},
		'build-deps-failed-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"build-deps-failed-commands"},
				$_[1]);
		},
		'build-failed-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"build-failed-commands"},
				$_[1]);
		},
		'anything-failed-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"chroot-update-failed-commands"},
				$_[1]);
		},
		'starting-build-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"starting-build-commands"},
				$_[1]);
		},
		'finished-build-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"finished-build-commands"},
				$_[1]);
		},
		'chroot-cleanup-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"chroot-cleanup-commands"},
				$_[1]);
		},
		'post-build-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"post-build-commands"},
				$_[1]);
		},
		'post-build-failed-commands=s' => sub {
			check_option_value(
				${ $_[0]->get_conf('EXTERNAL_COMMANDS') }
				  {"post-build-failed-commands"},
				$_[1]);
		},
		'extra-package=s' =>
		  sub { check_option_value($_[0]->get_conf('EXTRA_PACKAGES'), $_[1]); }
		,
		'extra-repository=s' => sub {
			check_option_value($_[0]->get_conf('EXTRA_REPOSITORIES'), $_[1]);
		},
		'extra-repository-key=s' => sub {
			check_option_value($_[0]->get_conf('EXTRA_REPOSITORY_KEYS'),
				$_[1]);
		},
	);

	keys %command_line_arguments
	  ; # reset the internal iterator so a prior each() doesn't affect the loop
	while (my ($key, $option_extractor) = each %command_line_arguments) {
		# Get the argument string to be put in the command line
		my $argument = $key;
		$argument =~ s/=.*//g;
		$argument =~ s/.*\|//g;

		subtest "$key as argument $argument" => sub {
		# Check that we recognize the GetOptions argument format.
		# If a new specifier is used, the test need to be adjusted to test that
		# argument.
			if ($key =~ /=i$/) {
				# Integer value, use arbitrary value 15 for the test.
				my $test_value = 15;
				check_argument($argument, $option_extractor, $test_value);
			} elsif ($key =~ /=s$/) {
				# String value
				my $test_value = "test-string";
				check_argument($argument, $option_extractor, $test_value);
			} elsif ($key =~ /[=:!\+].?$/) {
				die "Unsupported argument specifier: $key";
			} elsif ($key !~ /^[A-Za-z0-9-\|\?]+$/) {
				die "Unsupported argument specifier: $key";
			} else {
				# No additional value
				check_bool_argument($argument, $option_extractor);
			}
		}
	}

	# Check that combined arguments are merged in the array.
	my @command_line_multiple_arguments = (([
				'--autopkgtest-opts=value1 value2',
				'--autopkgtest-opt=value3',
				'--autopkgtest-opt=value4'
			],
			sub {
				check_option_array_contains($_[0], 'AUTOPKGTEST_OPTIONS',
					'value1', 'value2', 'value3', 'value4');
			}
		),
		([
				'--autopkgtest-root-args=value1 value2',
				'--autopkgtest-root-arg=value3',
				'--autopkgtest-root-arg=value4'
			],
			sub {
				check_option_array_contains($_[0], 'AUTOPKGTEST_ROOT_ARGS',
					'value1', 'value2', 'value3', 'value4');
			}
		),
		([
				'--piuparts-opts=value1 value2', '--piuparts-opt=value3',
				'--piuparts-opt=value4'
			],
			sub {
				check_option_array_contains($_[0], 'PIUPARTS_OPTIONS',
					'value1', 'value2', 'value3', 'value4');
			}
		),
		([
				'--piuparts-root-args=value1 value2',
				'--piuparts-root-arg=value3',
				'--piuparts-root-arg=value4'
			],
			sub {
				check_option_array_contains($_[0], 'PIUPARTS_ROOT_ARGS',
					'value1', 'value2', 'value3', 'value4');
			}
		),
		([
				'--lintian-opts=value1 value2', '--lintian-opt=value3',
				'--lintian-opt=value4'
			],
			sub {
				check_option_array_contains($_[0], 'LINTIAN_OPTIONS',
					'value1', 'value2', 'value3', 'value4');
			}
		),
		([
				'--dpkg-source-opts=value1 value2',
				'--dpkg-source-opt=value3',
				'--dpkg-source-opt=value4'
			],
			sub {
				check_option_array_contains($_[0], 'DPKG_SOURCE_OPTIONS',
					'value1', 'value2', 'value3', 'value4');
			}
		),
		([
				'--debbuildopts=value1 value2', '--debbuildopt=value3',
				'--debbuildopt=value4'
			],
			sub {
				check_option_array_contains($_[0],
					'DPKG_BUILDPACKAGE_USER_OPTIONS',
					'value1', 'value2', 'value3', 'value4');
			}
		),
		([
				'--autopkgtest-virt-server-opts=value1 value2',
				'--autopkgtest-virt-server-opt=value3',
				'--autopkgtest-virt-server-opt=value4'
			],
			sub {
				check_option_array_contains($_[0],
					'AUTOPKGTEST_VIRT_SERVER_OPTIONS',
					'value1', 'value2', 'value3', 'value4');
			}
		),
	);
	while (@command_line_multiple_arguments) {
		my ($arguments, $check_function)
		  = splice(@command_line_multiple_arguments, 0, 2);

		subtest "arguments" => sub {
			@ARGV        = ("sbuild", @$arguments);
			@TESTED_ARGV = @ARGV;

			my $options = run_sbuild_argument_parser();

			$check_function->($options);
		}
	}
}

main();
done_testing();
