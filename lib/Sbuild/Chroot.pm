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

package Sbuild::Chroot;

use Sbuild qw(copy debug debug2);
use Sbuild::Base;
use Sbuild::ChrootInfo;
use Sbuild::ChrootSetup qw(basesetup);
use Sbuild qw($devnull shellescape);

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();
use File::Basename qw(basename);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    my @filter;
    @filter = @{$self->get_conf('ENVIRONMENT_FILTER')}
	if (defined($self->get_conf('ENVIRONMENT_FILTER')));

    $self->set('Session ID', "");
    $self->set('Chroot ID', $chroot_id) if defined $chroot_id;
    $self->set('Defaults', {
	'COMMAND' => [],
	'INTCOMMAND' => [], # Private
	'EXPCOMMAND' => [], # Private
	'ENV' => {},
	'ENV_FILTER' => \@filter,
	'USER' => 'root',
	'CHROOT' => 1,
	'PRIORITY' => 0,
	'DIR' => '/',
	'SETSID' => 0,
	'STREAMIN' => undef,
	'STREAMOUT' => undef,
	'STREAMERR' => undef});

    return $self;
}

sub _setup_options {
    my $self = shift;

    if (basesetup($self, $self->get('Config'))) {
	print STDERR "Failed to set up chroot\n";
	return 0;
    }

    return 1;
}

sub get_option {
    my $self = shift;
    my $options = shift;
    my $option = shift;

    my $value = undef;
    $value = $self->get('Defaults')->{$option} if
	(defined($self->get('Defaults')) &&
	 defined($self->get('Defaults')->{$option}));
    $value = $options->{$option} if
	(defined($options) &&
	 exists($options->{$option}));

    return $value;
}

sub log_command {
    my $self = shift;
    my $options = shift;

    my $priority = $options->{'PRIORITY'};

    if ((defined($priority) && $priority >= 1) || $self->get_conf('DEBUG')) {
	my $command;
	if ($self->get_conf('DEBUG')) {
	    $command = $options->{'EXPCOMMAND'};
	} else {
	    $command = $options->{'COMMAND'};
	}

	$self->log_info(join(" ", @$command), "\n");
    }
}

# create a temporary file or directory inside the chroot
sub mktemp {
    my $self = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    my $mktempcmd = ['mktemp'];

    if (defined $options->{'DIRECTORY'} && $options->{'DIRECTORY'}) {
	push(@{$mktempcmd}, "-d");
    }

    if (defined $options->{'TEMPLATE'}) {
	push(@{$mktempcmd}, $options->{'TEMPLATE'});
    }

    my $pipe = $self->pipe_command({ COMMAND => $mktempcmd, USER => $user, DIR => $dir });
    if (!$pipe) {
	$self->log_error("cannot open pipe\n");
	return;
    }
    chomp (my $tmpdir = do { local $/; <$pipe> });
    close $pipe;
    if ($?) {
	if (defined $options->{'TEMPLATE'}) {
	    $self->log_error("cannot run mktemp " . $options->{'TEMPLATE'} . ": $!\n");
	} else {
	    $self->log_error("cannot run mktemp: $!\n");
	}
	return;
    }
    return $tmpdir;
}

# copy a file from the outside into the chroot
sub copy_to_chroot {
    my $self = shift;
    my $source = shift;
    my $dest = shift;
    my $options = shift;

    # if the destination inside the chroot is a directory, then the file has
    # to be copied into that directory with the same filename as outside
    if($self->test_directory($dest)) {
	$dest .= '/' . (basename $source);
    }

    my $pipe = $self->get_write_file_handle($dest, $options);
    if (!defined $pipe) {
	$self->log_error("get_write_file_handle failed\n");
	return;
    }

    local *INFILE;
    if(!open(INFILE, "<", $source)) {
	$self->log_error("cannot open $source\n");
	close $pipe;
	return;
    }

    while ( (read (INFILE, my $buffer, 65536)) != 0 ) {
	print $pipe $buffer;
    }

    close INFILE;
    close $pipe;

    return 1;
}

# copy a file inside the chroot to the outside
sub copy_from_chroot {
    my $self = shift;
    my $source = shift;
    my $dest = shift;
    my $options = shift;

    my $pipe = $self->get_read_file_handle($source, $options);
    if (!defined $pipe) {
	$self->log_error("get_read_file_handle failed\n");
	return;
    }

    # if the destination outside the chroot is a directory, then the file has
    # to be copied into that directory with the same filename as inside
    if (-d $dest) {
	$dest .= '/' . (basename $source);
    }

    local *OUTFILE;
    if(!open(OUTFILE, ">", $dest)) {
	$self->log_error("cannot open $dest\n");
	close $pipe;
	return;
    }

    while ( (read ($pipe, my $buffer, 65536)) != 0 ) {
	print OUTFILE $buffer;
    }

    close OUTFILE;
    close $pipe;

    return 1;
}

# returns a file handle to read a file inside the chroot
sub get_read_file_handle {
    my $self = shift;
    my $source = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    my $escapedsource = shellescape $source;

    my $pipe = $self->pipe_command({
	    COMMAND => [ "sh", "-c", "cat $escapedsource" ],
	    DIR => $dir,
	    USER => $user,
	    PIPE => 'in'
	});
    if (!$pipe) {
	$self->log_error("cannot open pipe\n");
	return;
    }

    return $pipe;
}

# returns a string with the content of a file inside the chroot
sub read_file {
    my $self = shift;
    my $source = shift;
    my $options = shift;

    my $pipe = $self->get_read_file_handle($source, $options);
    if (!defined $pipe) {
	$self->log_error("get_read_file_handle failed\n");
	return;
    }

    my $content = do { local $/; <$pipe> };
    close $pipe;

    return $content;
}

# returns a file handle to write to a file inside the chroot
sub get_write_file_handle {
    my $self = shift;
    my $dest = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    my $escapeddest = shellescape $dest;

    my $pipe = $self->pipe_command({
	    COMMAND => [ "sh", "-c", "cat > $escapeddest" ],
	    DIR => $dir,
	    USER => $user,
	    PIPE => 'out'
	});
    if (!$pipe) {
	$self->log_error("cannot open pipe\n");
	return;
    }

    return $pipe;
}

sub read_command {
    my $self = shift;
    my $options = shift;

    $options->{PIPE} = "in";

    my $pipe = $self->pipe_command($options);
    if (!$pipe) {
	$self->log_error("cannot open pipe\n");
	return;
    }

    my $content = do { local $/; <$pipe> };
    close $pipe;

    if ($?) {
	$self->log_error("read_command failed to execute " . $options->{COMMAND}->[0] . "\n");
	return;
    }

    return $content;
}

# writes a string to a file inside the chroot
sub write_file {
    my $self = shift;
    my $dest = shift;
    my $content = shift;
    my $options = shift;

    my $pipe = $self->get_write_file_handle($dest, $options);
    if (!defined $pipe) {
	$self->log_error("get_read_file_handle failed\n");
	return;
    }

    print $pipe $content;
    close $pipe;

    return 1;
}

sub write_command {
    my $self = shift;
    my $content = shift;
    my $options = shift;

    $options->{PIPE} = "out";

    my $pipe = $self->pipe_command($options);
    if (!$pipe) {
	$self->log_error("cannot open pipe\n");
	return;
    }

    if(!print $pipe $content) {
	$self->log_error("failed to print to file handle\n");
	close $pipe;
    }

    close $pipe;

    if ($?) {
	$self->log_error("write_command failed to execute " . $options->{COMMAND}->[0] . "\n");
	return;
    }

    return 1;
}

# rename a file inside the chroot
sub rename {
    my $self = shift;
    my $source = shift;
    my $dest = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    $self->run_command({ COMMAND => ["mv", $source, $dest], USER => $user, DIR => $dir});
    if ($?) {
	$self->log_error("Can't rename $source to $dest: $!\n");
	return 0;
    }

    return 1;
}

# create a directory inside the chroot
sub mkdir {
    my $self = shift;
    my $path = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    my $mkdircmd = [ "mkdir", $path ];

    if (defined $options->{'PARENTS'} && $options->{'PARENTS'}) {
	push(@{$mkdircmd}, "-p");
    }

    if (defined $options->{'MODE'}) {
	push(@{$mkdircmd}, "--mode", $options->{'MODE'});
    }

    $self->run_command({ COMMAND => $mkdircmd, USER => $user, DIR => $dir});
    if ($?) {
	$self->log_error("Can't mkdir $path: $!\n");
	return 0;
    }

    return 1;
}

sub test_internal {
    my $self = shift;
    my $path = shift;
    my $arg = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    $self->run_command({ COMMAND => [ "test", $arg, $path ], USER => $user, DIR => $dir});
    if ($? eq 0) {
	return 1;
    } else {
	return 0;
    }
}

# test if a path inside the chroot is a directory
sub test_directory {
    my $self = shift;
    my $path = shift;
    my $options = shift;

    return $self->test_internal($path, "-d", $options);
}

# test if a path inside the chroot is a regular file
sub test_regular_file {
    my $self = shift;
    my $path = shift;
    my $options = shift;

    return $self->test_internal($path, "-f", $options);
}

# test if a path inside the chroot is a regular readable file
sub test_regular_file_readable {
    my $self = shift;
    my $path = shift;
    my $options = shift;

    return $self->test_internal($path, "-r", $options);
}

# test if a path inside the chroot is a symlink
sub test_symlink {
    my $self = shift;
    my $path = shift;
    my $options = shift;

    return $self->test_internal($path, "-L", $options);
}

# remove a file inside the chroot
sub unlink {
    my $self = shift;
    my $path = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    my $rmcmd = [ "rm", $path ];

    if (defined $options->{'RECURSIVE'} && $options->{'RECURSIVE'}) {
	push(@{$rmcmd}, "-r");
    }

    if (defined $options->{'FORCE'} && $options->{'FORCE'}) {
	push(@{$rmcmd}, "-f");
    }

    if (defined $options->{'DIRECTORY'} && $options->{'DIRECTORY'}) {
	push(@{$rmcmd}, "-d");
    }

    $self->run_command({ COMMAND => $rmcmd, USER => $user, DIR => $dir});
    if ($?) {
	$self->log_error("Can't unlink $path: $!\n");
	return 0;
    }

    return 1;
}

# chmod a path inside the chroot
sub chmod {
    my $self = shift;
    my $path = shift;
    my $mode = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    my $chmodcmd = [ "chmod" ];

    if (defined $options->{'RECURSIVE'} && $options->{'RECURSIVE'}) {
	push(@{$chmodcmd}, "-R");
    }

    push(@{$chmodcmd}, $mode, $path);

    $self->run_command({ COMMAND => $chmodcmd, USER => $user, DIR => $dir});
    if ($?) {
	$self->log_error("Can't chmod $path to $mode: $!\n");
	return 0;
    }

    return 1;
}

# chown a path inside the chroot
sub chown {
    my $self = shift;
    my $path = shift;
    my $owner = shift;
    my $group = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    my $chowncmd = [ "chown" ];

    if (defined $options->{'RECURSIVE'} && $options->{'RECURSIVE'}) {
	push(@{$chowncmd}, "-R");
    }

    push(@{$chowncmd}, "$owner:$group", $path);

    $self->run_command({ COMMAND => $chowncmd, USER => $user, DIR => $dir});
    if ($?) {
	$self->log_error("Can't chown $path to $owner:$group: $!\n");
	return 0;
    }

    return 1;
}

# test if a program inside the chroot can be run
# we use the function name "can_run" as it is similar to the function in
# IPC::Cmd
sub can_run {
    my $self = shift;
    my $program = shift;
    my $options = shift;

    my $user = "root";
    $user = $options->{'USER'} if defined $options->{'USER'};

    my $dir = "/";
    $dir = $options->{'DIR'} if defined $options->{'DIR'};

    my $escapedprogram = shellescape $program;

    my $commandcmd = [ 'sh', '-c', "command -v $escapedprogram >/dev/null 2>&1" ];

    $self->run_command({ COMMAND => $commandcmd, USER => $user, DIR => $dir});
    if ($?) {
	return 0;
    }

    return 1;
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub pipe_command_internal {
    my $self = shift;
    my $options = shift;

    my $pipetype = "-|";
    $pipetype = "|-" if (defined $options->{'PIPE'} &&
			 $options->{'PIPE'} eq 'out');

    my $pipe = undef;
    my $pid = open($pipe, $pipetype);
    if (!defined $pid) {
	warn "Cannot open pipe: $!\n";
    } elsif ($pid == 0) { # child
	if (!defined $options->{'PIPE'} ||
	    $options->{'PIPE'} ne 'out') { # redirect stdin
	    my $in = $self->get_option($options, 'STREAMIN');
	    if (defined($in) && $in && \*STDIN != $in) {
		open(STDIN, '<&', $in)
		    or warn "Can't redirect stdin\n";
	    }
	} else { # redirect stdout
	    my $out = $self->get_option($options, 'STREAMOUT');
	    if (defined($out) && $out && \*STDOUT != $out) {
		open(STDOUT, '>&', $out)
		    or warn "Can't redirect stdout\n";
	    }
	}
	# redirect stderr
	my $err = $self->get_option($options, 'STREAMERR');
	if (defined($err) && $err && \*STDERR != $err) {
	    open(STDERR, '>&', $err)
		or warn "Can't redirect stderr\n";
	}

	my $setsid = $self->get_option($options, 'SETSID');
	setsid() if defined($setsid) && $setsid;

	$self->exec_command($options);
    }

    debug2("Pipe (PID $pid, $pipe) created for: ",
	   join(" ", @{$options->{'COMMAND'}}),
	   "\n");

    $options->{'PID'} = $pid;

    return $pipe;
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub run_command_internal {
    my $self = shift;
    my $options = shift;

    my $pid = fork();

    if (!defined $pid) {
	warn "Cannot fork: $!\n";
    } elsif ($pid == 0) { # child

	# redirect stdin
	my $in = $self->get_option($options, 'STREAMIN');
	if (defined($in) && $in && \*STDIN != $in) {
	    open(STDIN, '<&', $in)
		or warn "Can't redirect stdin\n";
	}

	# redirect stdout
	my $out = $self->get_option($options, 'STREAMOUT');
	if (defined($out) && $out && \*STDOUT != $out) {
	    open(STDOUT, '>&', $out)
		or warn "Can't redirect stdout\n";
	}

	# redirect stderr
	my $err = $self->get_option($options, 'STREAMERR');
	if (defined($err) && $err && \*STDERR != $err) {
	    open(STDERR, '>&', $err)
		or warn "Can't redirect stderr\n";
	}

	my $setsid = $self->get_option($options, 'SETSID');
	setsid() if defined($setsid) && $setsid;

	$self->exec_command($options);
    }

    debug2("Pipe (PID $pid) created for: ",
	   join(" ", @{$options->{'COMMAND'}}),
	   "\n");

    waitpid($pid, 0);
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub run_command {
    my $self = shift;
    my $options = shift;

    $options->{'INTCOMMAND'} = copy($options->{'COMMAND'});
    $options->{'INTCOMMAND_STR'} = copy($options->{'COMMAND_STR'});

    return $self->run_command_internal($options);
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub pipe_command {
    my $self = shift;
    my $options = shift;

    $options->{'INTCOMMAND'} = copy($options->{'COMMAND'});
    $options->{'INTCOMMAND_STR'} = copy($options->{'COMMAND_STR'});

    return $self->pipe_command_internal($options);
}

sub get_internal_exec_string {
    return;
}

# This function must not print anything to standard output or standard error
# when it dies because its output will be treated as the output of the program
# it executes. So error handling can only happen with "die()".
sub exec_command {
    my $self = shift;
    my $options = shift;

    my @filter;
    my $chrootfilter = $self->get('Defaults')->{'ENV_FILTER'};
    push(@filter, @{$chrootfilter});

    my $commandfilter = $options->{'ENV_FILTER'};
    push(@filter, @{$commandfilter}) if defined($commandfilter);

    # Sanitise environment
    foreach my $var (keys %ENV) {
	my $match = 0;
	foreach my $regex (@filter) {
	    $match = 1 if
		$var =~ m/($regex)/;
	}
	delete $ENV{$var} if
	    $match == 0;
	if (!$match) {
	    debug2("Environment filter: Deleted $var\n");
	} else {
	    debug2("Environment filter: Kept $var\n");
	}
    }

    my $chrootenv = $self->get('Defaults')->{'ENV'};
    foreach (keys %$chrootenv) {
	$ENV{$_} = $chrootenv->{$_};
    }

    my $commandenv = $options->{'ENV'};
    foreach (keys %$commandenv) {
	$ENV{$_} = $commandenv->{$_};
    }

    # get_command_internal has to be called *after* $ENV was set because
    # depending on the backend, environment variables have to be handled
    # differently. For example the autopkgtest backend has to insert an
    # explicit call to env into the command so that the environment variables
    # survive.
    $self->get_command_internal($options);

    if (!defined($options->{'EXPCOMMAND'}) || $options->{'EXPCOMMAND'} eq ''
	|| !defined($options->{'COMMAND'}) || scalar(@{$options->{'COMMAND'}}) == 0
	|| !defined($options->{'INTCOMMAND'}) || scalar(@{$options->{'INTCOMMAND'}}) == 0) {
	die "get_command_internal failed during exec_command\n";
    }

    $self->log_command($options);

    my $command = $options->{'EXPCOMMAND'};

    my $program = $command->[0];
    $program = $options->{'PROGRAM'} if defined($options->{'PROGRAM'});

    debug2("PROGRAM: $program\n");
    debug2("COMMAND: ", join(" ", @{$options->{'COMMAND'}}), "\n");
    debug2("COMMAND_STR: ", $options->{'COMMAND'} // 'UNDEFINED', "\n");
    debug2("INTCOMMAND: ", join(" ", @{$options->{'INTCOMMAND'}}), "\n");
    debug2("INTCOMMAND_STR: ", $options->{'INTCOMMAND_STR:'} // 'UNDEFINED', "\n");
    debug2("EXPCOMMAND: ", join(" ", @{$options->{'EXPCOMMAND'}}), "\n");

    debug2("Environment set:\n");
    foreach (sort keys %ENV) {
	debug2('  ' . $_ . '=' . ($ENV{$_} || '') . "\n");
    }

    debug("Running command: ", join(" ", @$command), "\n");
    exec { $program } @$command;
    die "Failed to exec: $command->[0]: $!";
}

sub lock_chroot {
    my $self = shift;
    my $new_job = shift;
    my $new_pid = shift;
    my $new_user = shift;

    my $lockfile = '/var/lock/sbuild';
    my $max_trys = $self->get_conf('MAX_LOCK_TRYS');
    my $lock_interval = $self->get_conf('LOCK_INTERVAL');

    # The following command in run /inside/ the chroot to create the lockfile.
    my $command = <<"EOF";

    use strict;
    use warnings;
    use POSIX;
    use FileHandle;

    my \$lockfile="$lockfile";
    my \$try = 0;

  repeat:
    if (!sysopen( F, \$lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
	if (\$! == EEXIST) {
	    # lock file exists, wait
	    goto repeat if !open( F, "<\$lockfile" );
	    my \$line = <F>;
	    my (\$job, \$pid, \$user);
	    close( F );
	    if (\$line !~ /^(\\S+)\\s+(\\S+)\\s+(\\S+)/) {
		print STDERR "Bad lock file contents (\$lockfile) -- still trying\\n";
	    } else {
		(\$job, \$pid, \$user) = (\$1, \$2, \$3);
		if (kill( 0, \$pid ) == 0 && \$! == ESRCH) {
		    # process no longer exists, remove stale lock
		    print STDERR "Removing stale lock file \$lockfile ".
			"(job \$job, pid \$pid, user \$user)\\n";
		    if (!unlink(\$lockfile)) {
			if (\$! != ENOENT) {
			    print STDERR "Cannot remove chroot lock file \$lockfile: \$!\\n";
			    exit 1;
			}
		    }
		}
	    }
	    ++\$try;
	    if (\$try > $max_trys) {
		print STDERR "Lockfile \$lockfile still present after " .
		    $max_trys * $lock_interval . " seconds -- giving up\\n";
		exit 1;
	    }
	    print STDERR "Another sbuild process (job \$job, pid \$pid by user \$user) is currently using the build chroot; waiting...\\n"
		if \$try == 1;
	    sleep $lock_interval;
	    goto repeat;
	} else {
	    print STDERR "Failed to create lock file \$lockfile: \$!\\n";
	    exit 1;
	}
    }

    F->print("$new_job $new_pid $new_user\\n");
    F->close();

    exit 0;
EOF

    $self->run_command(
	    { COMMAND => ['perl',
			  '-e',
			  $command],
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });

    if ($?) {
	return 0;
    }
    return 1;
}

sub unlock_chroot {
    my $self = shift;

    my $lockfile = '/var/lock/sbuild';

    # The following command in run /inside/ the chroot to remove the lockfile.
    my $command = <<"EOF";

    use strict;
    use warnings;
    use POSIX;

    my \$lockfile="$lockfile";
    if (!unlink(\$lockfile)) {
	print STDERR "Cannot remove chroot lock file \$lockfile: \$!\\n"
	    if \$! != ENOENT;
	exit 1;
    }
    exit 0;
EOF

    debug("Removing chroot lock file $lockfile\n");
    $self->run_command(
	    { COMMAND => ['perl',
			  '-e',
			  $command],
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });

    if ($?) {
	return 0;
    }
    return 1;
}

sub useradd {
    my $self = shift;
    my @args = @_;
    $self->run_command(
        { COMMAND => ['useradd', @args],
	  USER => 'root',
	  STREAMIN => $devnull,
	  STREAMOUT => $devnull,
	  DIR => '/' });
    if ($?) {
	return 1;
    }
    return 0;
}

sub groupadd {
    my $self = shift;
    my @args = @_;
    $self->run_command(
	    { COMMAND => ['groupadd', @args],
	      USER => 'root',
	      STREAMIN => $devnull,
	      STREAMOUT => $devnull,
	      DIR => '/' });
    if ($?) {
	return 1;
    }
    return 0;
}

1;
