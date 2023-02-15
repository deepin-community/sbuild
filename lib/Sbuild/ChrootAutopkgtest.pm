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

package Sbuild::ChrootAutopkgtest;

use strict;
use warnings;

use POSIX qw(setsid);
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

    $self->set('Autopkgtest Pipe In', undef);
    $self->set('Autopkgtest Pipe Out', undef);
    $self->set('Autopkgtest Virt PID', undef);

    return $self;
}

sub begin_session {
    my $self = shift;

    # We are manually setting up bidirectional communication with autopkgtest
    # instead of using IPC::Open2 because we must call setsid() from the
    # child.
    #
    # Calling setsid() is necessary to place autopkgtest into a new process
    # group and thus prevent it from receiving for example a Ctrl+C that can be
    # sent by the user from a terminal. If autopkgtest would receive the
    # SIGINT, then it would close the session immediately without us being able
    # to do anything about it. Instead, we want to close the session later
    # ourselves.
    pipe(my $prnt_out, my $chld_in);
    pipe(my $chld_out, my $prnt_in);

    my $pid = fork();
    if (!defined $pid) {
	die "Cannot fork: $!";
    } elsif ($pid == 0) {
	# child
	close($chld_in);
	close($chld_out);

	# redirect stdin
	open(STDIN, '<&', $prnt_out)
	    or die "Can't redirect stdin\n";

	# redirect stdout
	open(STDOUT, '>&', $prnt_in)
	    or die "Can't redirect stdout\n";

	# put process into new group
	setsid();

	my @command = ($self->get_conf('AUTOPKGTEST_VIRT_SERVER'),
	    @{$self->get_conf('AUTOPKGTEST_VIRT_SERVER_OPTIONS')});
	exec { $self->get_conf('AUTOPKGTEST_VIRT_SERVER') } @command;
	die "Failed to exec $self->get_conf('AUTOPKGTEST_VIRT_SERVER'): $!";
    }
    close($prnt_out);
    close($prnt_in);

    # We must enable autoflushing for the stdin of the child process or
    # otherwise the commands we write will never reach the child.
    $chld_in->autoflush(1);

    if (!$pid) {
	print STDERR "Chroot setup failed\n";
	return 0;
    }

    my $status = <$chld_out>;

    if (!defined $status) {
	print STDERR "Undefined chroot status\n";
	return 0;
    }

    chomp $status;

    if (! defined $status || $status ne "ok") {
	print STDERR "autopkgtest-virt server returned unexpected value: $status\n";
	kill 'KILL', $pid;
	return 0;
    }

    print $chld_in "open\n";

    $status = <$chld_out>;

    if (!defined $status) {
	print STDERR "Undefined return value after 'open'\n";
	return 0;
    }

    chomp $status;

    my $autopkgtest_session;
    if ($status =~ /^ok (.*)$/) {
	$autopkgtest_session = $1;
	$self->set('Session ID', $autopkgtest_session);
    } else {
	print STDERR "autopkgtest-virt server: cannot open: $status\n";
	kill 'KILL', $pid;
	return 0;
    }

    print STDERR "Setting up chroot with session id $autopkgtest_session\n"
	if $self->get_conf('DEBUG');

    print $chld_in "capabilities\n";

    chomp ($status = <$chld_out>);

    my @capabilities;
    if ($status =~ /^ok (.*)$/) {
	@capabilities = split /\s+/, $1;
    } else {
	print STDERR "autopkgtest-virt server: cannot capabilities: $status\n";
	kill 'KILL', $pid;
	return 0;
    }

    if (! grep {$_ eq "root-on-testbed"} @capabilities) {
	print STDERR "autopkgtest-virt server: capability root-on-testbed missing\n";
	kill 'KILL', $pid;
	return 0;
    }

    # TODO: also test "revert" capability

    print $chld_in "print-execute-command\n";

    chomp ($status = <$chld_out>);

    my $exec_cmd;
    if ($status =~ /^ok (.*)$/) {
	$exec_cmd = $1;
    } else {
	print STDERR "autopkgtest-virt server: cannot print-execute-command: $status\n";
	kill 'KILL', $pid;
	return 0;
    }

    my @exec_args = split /,/, $exec_cmd;

    @exec_args = map { s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg; $_ } @exec_args;

    $self->set('Location', '/autopkgtest-virt-dummy-location');
    $self->set('Autopkgtest Pipe In', $chld_in);
    $self->set('Autopkgtest Pipe Out', $chld_out);
    $self->set('Autopkgtest Virt PID', $pid);
    $self->set('Autopkgtest Exec Command', \@exec_args);

    return 0 if !$self->_setup_options();

    return 1;
}

sub end_session {
    my $self = shift;

    return if $self->get('Session ID') eq "";

    print STDERR "Cleaning up chroot (session id " . $self->get('Session ID') . ")\n"
	if $self->get_conf('DEBUG');

    my $chld_in = $self->get('Autopkgtest Pipe In');
    my $chld_out = $self->get('Autopkgtest Pipe Out');
    my $pid = $self->get('Autopkgtest Virt PID');

    print $chld_in "close\n";

    my $status = <$chld_out>;

    if (!defined $status) {
	print STDERR "Undefined return value after 'close'\n";
	return 0;
    }

    chomp $status;

    if ($status ne "ok") {
	print STDERR "autopkgtest-virt server: cannot close: $status\n";
	return 0;
    }

    print $chld_in "quit\n";

    waitpid $pid, 0;

    if ($?) {
	my $child_exit_status = $? >> 8;
	print STDERR "autopkgtest-virt quit with exit status $child_exit_status\n";
	return 0;
    }

    close($chld_in);
    close($chld_out);

    $self->set('Autopkgtest Pipe In', undef);
    $self->set('Autopkgtest Pipe Out', undef);
    $self->set('Autopkgtest Virt PID', undef);

    return 1;
}

sub get_command_internal {
    my $self = shift;
    my $options = shift;

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

    my @cmdline = ();

    @cmdline = @{$self->get('Autopkgtest Exec Command')};

    push @cmdline, 'env';
    foreach my $var (keys %ENV) {
	push @cmdline, "$var=$ENV{$var}";
    }

    if ($user ne "root") {
	push @cmdline, "/sbin/runuser", '-u', $user, '--';
    }

    if (defined($dir)) {
	my $shelldir = shellescape $dir;
	push @cmdline, 'sh', '-c', "cd $shelldir && exec \"\$@\"", 'exec';
    } else {
	$dir = '/';
    }

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
