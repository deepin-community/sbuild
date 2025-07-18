#
# ClientConf.pm: configuration library for wanna-build clients
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2009 Roger Leigh <rleigh@debian.org>
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

package Buildd::ClientConf;

use strict;
use warnings;

use Sbuild::Sysconfig;
use File::Spec;

BEGIN {
	use Exporter ();
	our (@ISA, @EXPORT);

	@ISA = qw(Exporter);

	@EXPORT = qw(setup);
}

sub setup ($) {
	my $conf = shift;

	my $validate_program = sub {
		my $conf    = shift;
		my $entry   = shift;
		my $key     = $entry->{'NAME'};
		my $program = $conf->get($key);

		die "$key binary is not defined"
		  if !defined($program) || !$program;

		# Emulate execvp behaviour by searching the binary in the PATH.
		my @paths = split(/:/, $ENV{'PATH'});
		# Also consider the empty path for absolute locations.
		push(@paths, '');
		my $found = 0;
		foreach my $path (@paths) {
			$found = 1 if (-x File::Spec->catfile($path, $program));
		}

		die "$key binary '$program' does not exist or is not executable"
		  if !$found;
	};

	our $HOME = $conf->get('HOME');
	my $arch = $conf->get('ARCH');

	my @db_keys = (
		'SSH' => {
			TYPE    => 'STRING',
			VARNAME => 'ssh',
			GROUP   => 'Programs',
			DEFAULT => 'ssh',
			CHECK   => $validate_program,
			HELP    => 'Path to ssh binary'
		},
		'WANNA_BUILD_SSH_CMD' => {
			TYPE    => 'ARRAY:STRING',
			GROUP   => '__INTERNAL',
			DEFAULT => undef,
			GET     => sub {
				my $conf  = shift;
				my $entry = shift;

				my $ssh        = $conf->get('SSH');
				my $sshuser    = $conf->get('WANNA_BUILD_SSH_USER');
				my $sshhost    = $conf->get('WANNA_BUILD_SSH_HOST');
				my @sshoptions = @{ $conf->get('WANNA_BUILD_SSH_OPTIONS') };
				my $sshsocket  = $conf->get('WANNA_BUILD_SSH_SOCKET');

				my @command = ();

				if ($sshhost) {
					push(@command, $ssh);
					push(@command, '-l', $sshuser)   if $sshuser;
					push(@command, '-S', $sshsocket) if $sshsocket;
					push(@command, @sshoptions) if @sshoptions;
					push(@command, $sshhost);
				}

				return \@command;
			},
			HELP =>
'Command to run wanna-build (set automatically from the other wanna-build options)'
		},
		'WANNA_BUILD_SSH_USER' => {
			TYPE    => 'STRING',
			VARNAME => 'wanna_build_ssh_user',
			GROUP   => 'wanna-build client',
			DEFAULT => '',
			HELP    => 'Username for SSH connection'
		},
		'WANNA_BUILD_SSH_HOST' => {
			TYPE    => 'STRING',
			VARNAME => 'wanna_build_ssh_host',
			GROUP   => 'wanna-build client',
			DEFAULT => '',
			HELP    => 'Host for SSH connection'
		},
		'WANNA_BUILD_SSH_SOCKET' => {
			TYPE    => 'STRING',
			VARNAME => 'wanna_build_ssh_socket',
			GROUP   => 'wanna-build client',
			DEFAULT => '',
			HELP    => 'Socket for SSH connection'
		},
		'WANNA_BUILD_SSH_OPTIONS' => {
			TYPE    => 'ARRAY:STRING',
			VARNAME => 'wanna_build_ssh_options',
			GROUP   => 'wanna-build client',
			DEFAULT => [],
			HELP    => 'SSH options.  Note this is an array reference.'
		},
		'WANNA_BUILD_DB_NAME' => {
			TYPE    => 'STRING',
			VARNAME => 'wanna_build_db_name',
			GROUP   => 'wanna-build client',
			DEFAULT => undef,
			HELP    => 'Database name'
		},
		'WANNA_BUILD_DB_USER' => {
			TYPE    => 'STRING',
			VARNAME => 'wanna_build_db_user',
			GROUP   => 'wanna-build client',
			DEFAULT => $conf->get('USERNAME'),
			# arch:all packages must not differ depending on which user is
			# building the source package, so don't show the default for
			# example config and man page generation
			IGNORE_DEFAULT => 1,
			HELP           => 'Database user'
		},
		'BUILT_ARCHITECTURE' => {
			TYPE    => 'STRING',
			VARNAME => 'wanna_build_built_architecture',
			GROUP   => 'wanna-build client',
			DEFAULT => $arch,
		   # the $native_arch is different depending on the machine where
		   # sbuild is built but arch:all packages must not differ depending on
		   # the architecture they are built on, so don't show the default for
		   # example config and man page generation
			IGNORE_DEFAULT => 1,
			HELP           => 'Architecture for database'
		});

	$conf->set_allowed_keys(@db_keys);
}

1;
