#
# Chroot.pm: chroot library for sbuild
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

package Sbuild::ChrootSchroot;

use strict;
use warnings;

use Sbuild qw(shellescape);

BEGIN {
    use Exporter ();
    use Sbuild::Chroot;
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Chroot);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf, $chroot_id);
    bless($self, $class);

    return $self;
}

sub begin_session {
    my $self = shift;
    my $chroot = $self->get('Chroot ID');

    return 0 if !defined $chroot;

    # Don't use namespaces in compat mode.
    if ($Sbuild::Sysconfig::compat_mode) {
	$chroot =~ s/^[^:]+://msx;
    }

    my $schroot_session=readpipe($self->get_conf('SCHROOT') . " -c $chroot --begin-session");
    chomp($schroot_session);
    if ($?) {
	print STDERR "Chroot setup failed\n";
	return 0;
    }

    $self->set('Session ID', $schroot_session);
    print STDERR "Setting up chroot $chroot (session id $schroot_session)\n"
	if $self->get_conf('DEBUG');

    my $info = $self->get('Chroots')->get_info($schroot_session);
	if (defined($info) &&
	    defined($info->{'Location'}) && -d $info->{'Location'}) {
	    $self->set('Priority', $info->{'Priority'});
	    $self->set('Location', $info->{'Location'});
	    $self->set('Session Purged', $info->{'Session Purged'});
    } else {
	print STDERR $self->get('Chroot ID') . " chroot does not exist\n";
	return 0;
    }

    return 0 if !$self->_setup_options();

    return 1;
}

sub end_session {
    my $self = shift;

    return if $self->get('Session ID') eq "";

    print STDERR "Cleaning up chroot (session id " . $self->get('Session ID') . ")\n"
	if $self->get_conf('DEBUG');
    system($self->get_conf('SCHROOT'), '-c', $self->get('Session ID'), '--end-session');
    $self->set('Session ID', "");
    if ($?) {
	print STDERR "Chroot cleanup failed\n";
	return 0;
    }

    return 1;
}

sub _get_exec_argv {
    my $self = shift;
    my $dir = shift;
    my $user = shift;

    return ($self->get_conf('SCHROOT'),
	'-d', $dir,
	'-c', $self->get('Session ID'),
	'--run-session',
	@{$self->get_conf('SCHROOT_OPTIONS')},
	'-u', "$user", '-p', '--');
}

sub get_internal_exec_string {
    my $self = shift;

    return if $self->get('Session ID') eq "";

    return join " ", (map
	{ shellescape $_ }
	$self->_get_exec_argv('/', 'root'));
}

sub get_command_internal {
    my $self = shift;
    my $options = shift;

    return if $self->get('Session ID') eq "";

    if (defined($options->{'DISABLE_NETWORK'}) && $options->{'DISABLE_NETWORK'}) {
	print STDERR "Disabling the network for this command was requested but the schroot backend doesn't support this feature yet: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=802849\n" if $self->get_conf('DEBUG');
    }

    # Command to run. If I have a string, use it. Otherwise use the list-ref
    my $command = $options->{'INTCOMMAND_STR'} // $options->{'INTCOMMAND'};

    my $user = $options->{'USER'};          # User to run command under
    my $dir;                                # Directory to use (optional)
    $dir = $self->get('Defaults')->{'DIR'} if
	(defined($self->get('Defaults')) &&
	 defined($self->get('Defaults')->{'DIR'}));
    $dir = $options->{'DIR'} if
	defined($options->{'DIR'}) && $options->{'DIR'};

    if (!defined $user || $user eq "") {
	$user = $self->get_conf('USERNAME');
    }

    if (!defined($dir)) {
	$dir = '/';
    }

    my @cmdline = $self->_get_exec_argv($dir, $user);

    if (ref $command) {
        push @cmdline, @$command;
    } else {
        push @cmdline, ('/bin/sh', '-c', $command);
        $command = [split(/\s+/, $command)];
    }
    $options->{'USER'} = $user;
    $options->{'COMMAND'} = $command;
    $options->{'EXPCOMMAND'} = \@cmdline;
    $options->{'CHDIR'} = undef;
    $options->{'DIR'} = $dir;
}

1;
