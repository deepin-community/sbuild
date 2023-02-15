# Resolver.pm: build library for sbuild
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

package Sbuild::ResolverBase;

use strict;
use warnings;
use POSIX;
use Fcntl;
use File::Temp qw(mktemp);
use File::Basename qw(basename);
use File::Copy;
use MIME::Base64;

use Dpkg::Deps;
use Sbuild::Base;
use Sbuild qw(isin debug debug2);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $session = shift;
    my $host = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Session', $session);
    $self->set('Host', $host);
    $self->set('Changes', {});
    $self->set('AptDependencies', {});
    $self->set('Split', $self->get_conf('CHROOT_SPLIT'));
    # Typically set by Sbuild::Build, but not outside a build context.
    $self->set('Host Arch', $self->get_conf('HOST_ARCH'));
    $self->set('Build Arch', $self->get_conf('BUILD_ARCH'));
    $self->set('Build Profiles', $self->get_conf('BUILD_PROFILES'));
    $self->set('Multiarch Support', 1);
    $self->set('Initial Foreign Arches', {});
    $self->set('Added Foreign Arches', {});

    my $dummy_archive_list_file =
        '/etc/apt/sources.list.d/sbuild-build-depends-archive.list';
    $self->set('Dummy archive list file', $dummy_archive_list_file);

    my $extra_repositories_archive_list_file =
        '/etc/apt/sources.list.d/sbuild-extra-repositories.list';
    $self->set('Extra repositories archive list file', $extra_repositories_archive_list_file);

    my $extra_packages_archive_list_file =
        '/etc/apt/sources.list.d/sbuild-extra-packages-archive.list';
    $self->set('Extra packages archive list file', $extra_packages_archive_list_file);

    return $self;
}

sub add_extra_repositories {
    my $self = shift;
    my $session = $self->get('Session');

    # Add specified extra repositories into /etc/apt/sources.list.d/.
    # This has to be done this early so that the early apt
    # update/upgrade/distupgrade steps also consider the extra repositories.
    # If this step would be done too late, extra repositories would only be
    # considered when resolving build dependencies but not for upgrading the
    # base chroot.
    if (scalar @{$self->get_conf('EXTRA_REPOSITORIES')} > 0) {
	my $extra_repositories_archive_list_file = $self->get('Extra repositories archive list file');
	if ($session->test_regular_file($extra_repositories_archive_list_file)) {
	    $self->log_error("$extra_repositories_archive_list_file exists - will not write extra repositories to it\n");
	} else {
	    my $tmpfilename = $session->mktemp();

	    my $tmpfh = $session->get_write_file_handle($tmpfilename);
	    if (!$tmpfh) {
		$self->log_error("Cannot open pipe: $!\n");
		return 0;
	    }
	    for my $repospec (@{$self->get_conf('EXTRA_REPOSITORIES')}) {
		print $tmpfh "$repospec\n";
	    }
	    close $tmpfh;
	    # List file needs to be moved with root.
	    if (!$session->chmod($tmpfilename, '0644')) {
		$self->log("Failed to create apt list file for dummy archive.\n");
		$session->unlink($tmpfilename);
		return 0;
	    }
	    if (!$session->rename($tmpfilename, $extra_repositories_archive_list_file)) {
		$self->log("Failed to create apt list file for dummy archive.\n");
		$session->unlink($tmpfilename);
		return 0;
	    }
	}
    }
}

sub setup {
    my $self = shift;

    my $session = $self->get('Session');
    my $chroot_dir = $session->get('Location');

    #Set up dpkg config
    $self->setup_dpkg();

    my $aptconf = "/var/lib/sbuild/apt.conf";
    $self->set('APT Conf', $aptconf);

    my $chroot_aptconf = $session->get('Location') . "/$aptconf";
    $self->set('Chroot APT Conf', $chroot_aptconf);

    my $tmpaptconf = $session->mktemp({ TEMPLATE => "$aptconf.XXXXXX"});
    if (!$tmpaptconf) {
	$self->log_error("Can't create $chroot_aptconf.XXXXXX: $!\n");
	return 0;
    }

    my $F = $session->get_write_file_handle($tmpaptconf);
    if (!$F) {
	$self->log_error("Cannot open pipe: $!\n");
	return 0;
    }

    # Always write out apt.conf, because it may become outdated.
    if ($self->get_conf('APT_ALLOW_UNAUTHENTICATED')) {
	print $F qq(APT::Get::AllowUnauthenticated "true";\n);
    }
    print $F qq(APT::Install-Recommends "false";\n);
    print $F qq(APT::AutoRemove::SuggestsImportant "false";\n);
    print $F qq(APT::AutoRemove::RecommendsImportant "false";\n);
    print $F qq(Acquire::Languages "none";\n); # do not download translations

    if ($self->get_conf('APT_KEEP_DOWNLOADED_PACKAGES')) {
	print $F qq(APT::Keep-Downloaded-Packages "true";\n);
    } else {
	# remove packages from /var/cache/apt/archive/*.deb after installation
	print $F qq(APT::Keep-Downloaded-Packages "false";\n);
    }

    if ($self->get('Split')) {
	print $F "Dir \"$chroot_dir\";\n";
    }

    close $F;

    if (!$session->rename($tmpaptconf, $aptconf)) {
	$self->log_error("Can't rename $tmpaptconf to $aptconf: $!\n");
	return 0;
    }

    if (!$session->chown($aptconf, $self->get_conf('BUILD_USER'), 'sbuild')) {
	$self->log_error("Failed to set " . $self->get_conf('BUILD_USER') .
			 ":sbuild ownership on apt.conf at $aptconf\n");
	return 0;
    }
    if (!$session->chmod($aptconf, '0664')) {
	$self->log_error("Failed to set 0664 permissions on apt.conf at $aptconf\n");
	return 0;
    }

    # unsplit mode uses an absolute path inside the chroot, rather
    # than on the host system.
    if ($self->get('Split')) {
	$self->set('APT Options',
		   ['-o', "Dir::State::status=$chroot_dir/var/lib/dpkg/status",
		    '-o', "DPkg::Options::=--root=$chroot_dir",
		    '-o', "DPkg::Run-Directory=$chroot_dir"]);

	$self->set('Aptitude Options',
		   ['-o', "Dir::State::status=$chroot_dir/var/lib/dpkg/status",
		    '-o', "DPkg::Options::=--root=$chroot_dir",
		    '-o', "DPkg::Run-Directory=$chroot_dir"]);

	# sudo uses an absolute path on the host system.
	$session->get('Defaults')->{'ENV'}->{'APT_CONFIG'} =
	    $self->get('Chroot APT Conf');
    } else { # no split
	$self->set('APT Options', []);
	$self->set('Aptitude Options', []);
	$session->get('Defaults')->{'ENV'}->{'APT_CONFIG'} =
	    $self->get('APT Conf');
    }

    $self->add_extra_repositories();

    # Create an internal repository for packages given via --extra-package
    # If this step would be done too late, extra packages would only be
    # considered when resolving build dependencies but not for upgrading the
    # base chroot.
    if (scalar @{$self->get_conf('EXTRA_PACKAGES')} > 0) {
	my $extra_packages_archive_list_file = $self->get('Extra packages archive list file');
	if ($session->test_regular_file($extra_packages_archive_list_file)) {
	    $self->log_error("$extra_packages_archive_list_file exists - will not write extra packages archive list to it\n");
	} else {
	    #Prepare a path to place the extra packages
	    if (! defined $self->get('Extra packages path')) {
		my $tmpdir = $session->mktemp({ TEMPLATE => $self->get('Build Dir') . '/resolver-XXXXXX', DIRECTORY => 1});
		if (!$tmpdir) {
		    $self->log_error("mktemp -d " . $self->get('Build Dir') . '/resolver-XXXXXX failed\n');
		    return 0;
		}
		$self->set('Extra packages path', $tmpdir);
	    }
	    if (!$session->chown($self->get('Extra packages path'), $self->get_conf('BUILD_USER'), 'sbuild')) {
		$self->log_error("Failed to set " . $self->get_conf('BUILD_USER') .
		    ":sbuild ownership on extra packages dir\n");
		return 0;
	    }
	    if (!$session->chmod($self->get('Extra packages path'), '0770')) {
		$self->log_error("Failed to set 0770 permissions on extra packages dir\n");
		return 0;
	    }
	    my $extra_packages_dir = $self->get('Extra packages path');
	    my $extra_packages_archive_dir = $extra_packages_dir . '/apt_archive';
	    my $extra_packages_release_file = $extra_packages_archive_dir . '/Release';

	    $self->set('Extra packages archive directory', $extra_packages_archive_dir);
	    $self->set('Extra packages release file', $extra_packages_release_file);
	    my $extra_packages_archive_list_file = $self->get('Extra packages archive list file');

	    if (!$session->test_directory($extra_packages_dir)) {
		$self->log_warning('Could not create build-depends extra packages dir ' . $extra_packages_dir . ': ' . $!);
		return 0;
	    }
	    if (!($session->test_directory($extra_packages_archive_dir) || $session->mkdir($extra_packages_archive_dir, { MODE => "00775"}))) {
		$self->log_warning('Could not create build-depends extra packages archive dir ' . $extra_packages_archive_dir . ': ' . $!);
		return 0;
	    }

	    # Copy over all the extra binary packages from the host into the
	    # chroot
	    for my $deb (@{$self->get_conf('EXTRA_PACKAGES')}) {
		if (-f $deb) {
		    my $base_deb = basename($deb);
		    if ($session->test_regular_file("$extra_packages_archive_dir/$base_deb")) {
			$self->log_warning("$base_deb already exists in $extra_packages_archive_dir inside the chroot. Skipping...\n");
			next;
		    }
		    $self->log("Copying $deb to $session->get('Location')...\n");
		    $session->copy_to_chroot($deb, $extra_packages_archive_dir);
		} elsif (-d $deb) {
		    opendir(D, $deb);
		    while (my $f = readdir(D)) {
			next if (! -f "$deb/$f");
			next if ("$deb/$f" !~ /\.deb$/);
			if ($session->test_regular_file("$extra_packages_archive_dir/$f")) {
			    $self->log_warning("$f already exists in $extra_packages_archive_dir inside the chroot. Skipping...\n");
			    next;
			}
			$self->log("Copying $deb/$f to $session->get('Location')...\n");
			$session->copy_to_chroot("$deb/$f", $extra_packages_archive_dir);
		    }
		    closedir(D);
		} else {
		    $self->log_warning("$deb is neither a regular file nor a directory. Skipping...\n");
		}
	    }

	    # Do code to run apt-ftparchive
	    if (!$self->run_apt_ftparchive($self->get('Extra packages archive directory'))) {
		$self->log("Failed to run apt-ftparchive.\n");
		return 0;
	    }

	    # Write a list file for the extra packages archive if one not create yet.
	    if (!$session->test_regular_file($extra_packages_archive_list_file)) {
		my $tmpfilename = $session->mktemp();

		if (!$tmpfilename) {
		    $self->log_error("Can't create tempfile\n");
		    return 0;
		}

		my $tmpfh = $session->get_write_file_handle($tmpfilename);
		if (!$tmpfh) {
		    $self->log_error("Cannot open pipe: $!\n");
		    return 0;
		}

		# We always trust the extra packages apt repositories.
		print $tmpfh 'deb [trusted=yes] file://' . $extra_packages_archive_dir . " ./\n";
		print $tmpfh 'deb-src [trusted=yes] file://' . $extra_packages_archive_dir . " ./\n";

		close($tmpfh);
		# List file needs to be moved with root.
		if (!$session->chmod($tmpfilename, '0644')) {
		    $self->log("Failed to create apt list file for extra packages archive.\n");
		    $session->unlink($tmpfilename);
		    return 0;
		}
		if (!$session->rename($tmpfilename, $extra_packages_archive_list_file)) {
		    $self->log("Failed to create apt list file for extra packages archive.\n");
		    $session->unlink($tmpfilename);
		    return 0;
		}
	    }

	}
    }

    # Now, we'll add in any provided OpenPGP keys into the archive, so that
    # builds can (optionally) trust an external key for the duration of the
    # build.
    #
    # Keys have to be in a format that apt expects to land in
    # /etc/apt/trusted.gpg.d as they are just copied to there. We could also
    # support more formats by first importing them using gpg and then
    # exporting them but that would require gpg to be installed inside the
    # chroot.
    if (@{$self->get_conf('EXTRA_REPOSITORY_KEYS')}) {
	my $host = $self->get('Host');
	# remember whether running gpg worked or not
	my $has_gpg = 1;
	for my $repokey (@{$self->get_conf('EXTRA_REPOSITORY_KEYS')}) {
	    debug("Adding archive key: $repokey\n");
	    if (!-f $repokey) {
		$self->log("Failed to add archive key '${repokey}' - it doesn't exist!\n");
		return 0;
	    }
	    # key might be armored but apt requires keys in binary format
	    # We first try to run gpg from the host to convert the key into
	    # binary format (this works even when the key already is in binary
	    # format).
	    my $tmpfilename = mktemp("/tmp/tmp.XXXXXXXXXX");
	    if ($has_gpg == 1) {
		$host->run_command({
			COMMAND => ['gpg', '--yes', '--batch', '--output', $tmpfilename, '--dearmor', $repokey],
			USER => $self->get_conf('BUILD_USER'),
		    });
		if ($?) {
		    # don't try to use gpg again in later loop iterations
		    $has_gpg = 0;
		}
	    }
	    # If that doesn't work, then we manually convert the key
	    # as it is just base64 encoded data with a header and footer.
	    #
	    # The decoding of armored gpg keys can even be done from a shell
	    # script by using:
	    #
	    #    awk '/^$/{ x = 1; } /^[^=-]/{ if (x) { print $0; } ; }' | base64 -d
	    #
	    # As explained by dkg here: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=831409#67
	    if ($has_gpg == 0) {
		# Test if we actually have an armored key. Otherwise, no
		# conversion is needed.
		open my $fh, '<', $repokey;
		read $fh, my $first_line, 36;
		if ($first_line eq "-----BEGIN PGP PUBLIC KEY BLOCK-----") {
		    # Read the remaining part of the line until the newline.
		    # We do it like this because the line might contain
		    # additional whitespace characters or \r\n newlines.
		    <$fh>;
		    open my $out, '>', $tmpfilename;
		    # the file is an armored gpg key, so we convert it to the
		    # binary format
		    my $header = 1;
		    while( my $line = <$fh>) {
			chomp $line;
			# an empty line marks the end of the header
			if ($line eq "") {
			    $header = 0;
			    next;
			}
			if ($header == 1) {
			    next;
			}
			# the footer might contain lines starting with an
			# equal sign or minuses
			if ($line =~ /^[=-]/) {
			    last;
			}
			print $out (decode_base64($line));
		    }
		    close $out;
		}
		close $fh;
	    }
	    # we could use incrementing integers to number the extra
	    # repository keys but mktemp will also make sure that the new name
	    # doesn't exist yet and avoids the complexity of an additional
	    # variable
	    my $keyfilename = $session->mktemp({TEMPLATE => "/etc/apt/trusted.gpg.d/sbuild-extra-repository-XXXXXXXXXX.gpg"});
	    if (!$keyfilename) {
		$self->log_error("Can't create tempfile for external repository key\n");
		$session->unlink($keyfilename);
		unlink $tmpfilename;
		return 0;
	    }
	    if (!$session->copy_to_chroot($tmpfilename, $keyfilename)) {
		$self->log_error("Failed to copy external repository key $repokey into chroot $keyfilename\n");
		$session->unlink($keyfilename);
		unlink $tmpfilename;
		return 0;
	    }
	    unlink $tmpfilename;
	    if (!$session->chmod($keyfilename, '0644')) {
		$self->log_error("Failed to chmod $keyfilename inside the chroot\n");
		$session->unlink($keyfilename);
		return 0;
	    }
	}

    }

    # We have to do this early so that we can setup log filtering for the RESOLVERDIR
    # We only set it up, if 'Build Dir' was set. It is not when the resolver
    # is used by sbuild-createchroot, for example.
    #Prepare a path to build a dummy package containing our deps:
    if (! defined $self->get('Dummy package path') && defined $self->get('Build Dir')) {
	my $tmpdir = $session->mktemp({ TEMPLATE => $self->get('Build Dir') . '/resolver-XXXXXX', DIRECTORY => 1});
	if (!$tmpdir) {
	    $self->log_error("mktemp -d " . $self->get('Build Dir') . '/resolver-XXXXXX failed\n');
	    return 0;
	}
	$self->set('Dummy package path', $tmpdir);
    }

    return 1;
}

sub get_foreign_architectures {
    my $self = shift;

    my $session = $self->get('Session');

    $session->run_command({ COMMAND => ['dpkg', '--assert-multi-arch'],
                            USER => 'root'});
    if ($?)
    {
        $self->set('Multiarch Support', 0);
        $self->log_error("dpkg does not support multi-arch\n");
        return {};
    }

    my $foreignarchs = $session->read_command({ COMMAND => ['dpkg', '--print-foreign-architectures'], USER => 'root' });

    if (!defined($foreignarchs)) {
        $self->set('Multiarch Support', 0);
        $self->log_error("dpkg does not support multi-arch\n");
        return {};
    }

    if (!$foreignarchs)
    {
        debug("There are no foreign architectures configured\n");
        return {};
    }

    my %set;
    foreach my $arch (split /\s+/, $foreignarchs) {
	chomp $arch;
	next unless $arch;
	$set{$arch} = 1;
    }

    return \%set;
}

sub add_foreign_architecture {

    my $self = shift;
    my $arch = shift;

    # just skip if dpkg is to old for multiarch
    if (! $self->get('Multiarch Support')) {
	debug("not adding $arch because of no multiarch support\n");
	return 1;
    };

    # if we already have this architecture, we're done
    if ($self->get('Initial Foreign Arches')->{$arch}) {
	debug("not adding $arch because it is an initial arch\n");
	return 1;
    }
    if ($self->get('Added Foreign Arches')->{$arch}) {
	debug("not adding $arch because it has already been aded");
	return 1;
    }

    my $session = $self->get('Session');

    # FIXME - allow for more than one foreign arch
    $session->run_command(
                          # This is the Ubuntu dpkg 1.16.0~ubuntuN interface;
                          # we ought to check (or configure) which to use with
                          # check_dpkg_version:
                          #	{ COMMAND => ['sh', '-c', 'echo "foreign-architecture ' . $self->get('Host Arch') . '" > /etc/dpkg/dpkg.cfg.d/sbuild'],
                          #	  USER => 'root' });
                          # This is the Debian dpkg >= 1.16.2 interface:
                          { COMMAND => ['dpkg', '--add-architecture', $arch],
                            USER => 'root' });
    if ($?)
    {
        $self->log_error("Failed to set dpkg foreign-architecture config\n");
        return 0;
    }
    debug("Added foreign arch: $arch\n") if $arch;

    $self->get('Added Foreign Arches')->{$arch} = 1;
    return 1;
}

sub cleanup_foreign_architectures {
    my $self = shift;

    # just skip if dpkg is to old for multiarch
    if (! $self->get('Multiarch Support')) { return 1 };

    my $added_foreign_arches = $self->get('Added Foreign Arches');

    my $session = $self->get('Session');

    if (defined ($session->get('Session Purged')) && $session->get('Session Purged') == 1) {
	debug("Not removing foreign architectures: cloned chroot in use\n");
	return;
    }

    foreach my $arch (keys %{$added_foreign_arches}) {
        $self->log("Removing foreign architecture $arch\n");
        $session->run_command({ COMMAND => ['dpkg', '--remove-architecture', $arch],
                                USER => 'root',
                                DIR => '/'});
        if ($?)
        {
            $self->log_error("Failed to remove dpkg foreign-architecture $arch\n");
            return;
        }
    }
}

sub setup_dpkg {
    my $self = shift;

    my $session = $self->get('Session');

    # Record initial foreign arch state so it can be restored
    $self->set('Initial Foreign Arches', $self->get_foreign_architectures());

    if ($self->get('Host Arch') ne $self->get('Build Arch')) {
	$self->add_foreign_architecture($self->get('Host Arch'))
    }
}

sub cleanup {
    my $self = shift;

    #cleanup dpkg cross-config
    # rm /etc/dpkg/dpkg.cfg.d/sbuild
    $self->cleanup_apt_archive();
    $self->cleanup_foreign_architectures();
}

sub update {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), 'update'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub update_archive {
    my $self = shift;

    if (!$self->get_conf('APT_UPDATE_ARCHIVE_ONLY')) {
	# Update with apt-get; causes complete archive update
	$self->run_apt_command(
	    { COMMAND => [$self->get_conf('APT_GET'), 'update'],
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      DIR => '/' });
    } else {
	my $session = $self->get('Session');
	# Create an empty sources.list.d directory that we can set as
	# Dir::Etc::sourceparts to suppress the real one. /dev/null
	# works in recent versions of apt, but not older ones (we want
	# 448eaf8 in apt 0.8.0 and af13d14 in apt 0.9.3). Since this
	# runs against the target chroot's apt, be conservative.
	my $dummy_sources_list_d = $self->get('Dummy package path') . '/sources.list.d';
	if (!($session->test_directory($dummy_sources_list_d) || $session->mkdir($dummy_sources_list_d, { MODE => "00700"}))) {
	    $self->log_warning('Could not create build-depends dummy sources.list directory ' . $dummy_sources_list_d . ': ' . $!);
	    return 0;
	}

	# Run apt-get update pointed at our dummy archive list file, and
	# the empty sources.list.d directory, so that we only update
	# this one source. Since apt doesn't have all the sources
	# available to it in this run, any caches it generates are
	# invalid, so we then need to run gencaches with all sources
	# available to it. (Note that the tempting optimization to run
	# apt-get update -o pkgCacheFile::Generate=0 is broken before
	# 872ed75 in apt 0.9.1.)
	for my $list_file ($self->get('Dummy archive list file'),
			   $self->get('Extra packages archive list file'),
			   $self->get('Extra repositories archive list file')) {
	    if (!$session->test_regular_file_readable($list_file)) {
		next;
	    }
	    $self->run_apt_command(
		{ COMMAND => [$self->get_conf('APT_GET'), 'update',
			'-o', 'Dir::Etc::sourcelist=' . $list_file,
			'-o', 'Dir::Etc::sourceparts=' . $dummy_sources_list_d,
			'--no-list-cleanup'],
		    ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
		    USER => 'root',
		    DIR => '/' });
	    if ($? != 0) {
		return 0;
	    }
	}

	$self->run_apt_command(
	    { COMMAND => [$self->get_conf('APT_CACHE'), 'gencaches'],
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      DIR => '/' });
    }

    if ($? != 0) {
	return 0;
    }

    return 1;
}

sub upgrade {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-uy', '-o', 'Dpkg::Options::=--force-confold', 'upgrade'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub distupgrade {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-uy', '-o', 'Dpkg::Options::=--force-confold', 'dist-upgrade'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub clean {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-y', 'clean'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub autoclean {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-y', 'autoclean'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub autoremove {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-y', 'autoremove'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub add_dependencies {
    my $self = shift;
    my $pkg = shift;
    my $build_depends = shift;
    my $build_depends_arch = shift;
    my $build_depends_indep = shift;
    my $build_conflicts = shift;
    my $build_conflicts_arch = shift;
    my $build_conflicts_indep = shift;

    debug("Build-Depends: $build_depends\n") if $build_depends;
    debug("Build-Depends-Arch: $build_depends_arch\n") if $build_depends_arch;
    debug("Build-Depends-Indep: $build_depends_indep\n") if $build_depends_indep;
    debug("Build-Conflicts: $build_conflicts\n") if $build_conflicts;
    debug("Build-Conflicts-Arch: $build_conflicts_arch\n") if $build_conflicts_arch;
    debug("Build-Conflicts-Indep: $build_conflicts_indep\n") if $build_conflicts_indep;

    my $deps = {
	'Build Depends' => $build_depends,
	'Build Depends Arch' => $build_depends_arch,
	'Build Depends Indep' => $build_depends_indep,
	'Build Conflicts' => $build_conflicts,
	'Build Conflicts Arch' => $build_conflicts_arch,
	'Build Conflicts Indep' => $build_conflicts_indep
    };

    $self->get('AptDependencies')->{$pkg} = $deps;
}

sub uninstall_deps {
    my $self = shift;

    my( @pkgs, @instd, @rmvd );

    @pkgs = keys %{$self->get('Changes')->{'removed'}};
    debug("Reinstalling removed packages: @pkgs\n");
    $self->log("Failed to reinstall removed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'install', @pkgs);
    debug("Installed were: @instd\n");
    debug("Removed were: @rmvd\n");
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);

    @pkgs = keys %{$self->get('Changes')->{'installed'}};
    debug("Removing installed packages: @pkgs\n");
    $self->log("Failed to remove installed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'remove', @pkgs);
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);
}

sub set_installed {
    my $self = shift;

    foreach (@_) {
	$self->get('Changes')->{'installed'}->{$_} = 1;
    }
    debug("Added to installed list: @_\n");
}

sub set_removed {
    my $self = shift;
    foreach (@_) {
	$self->get('Changes')->{'removed'}->{$_} = 1;
	if (exists $self->get('Changes')->{'installed'}->{$_}) {
	    delete $self->get('Changes')->{'installed'}->{$_};
	    $self->get('Changes')->{'auto-removed'}->{$_} = 1;
	    debug("Note: $_ was installed\n");
	}
    }
    debug("Added to removed list: @_\n");
}

sub unset_installed {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'installed'}->{$_};
    }
    debug("Removed from installed list: @_\n");
}

sub unset_removed {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'removed'}->{$_};
	if (exists $self->get('Changes')->{'auto-removed'}->{$_}) {
	    delete $self->get('Changes')->{'auto-removed'}->{$_};
	    $self->get('Changes')->{'installed'}->{$_} = 1;
	    debug("Note: revived $_ to installed list\n");
	}
    }
    debug("Removed from removed list: @_\n");
}

sub dump_build_environment {
    my $self = shift;

    my $status = $self->get_dpkg_status();

    my $arch = $self->get('Arch');
    my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
    $self->log_subsection("Build environment");
    $self->log("Kernel: $sysname $release $version $arch ($machine)\n");

    $self->log("Toolchain package versions:");
    foreach my $name (sort keys %{$status}) {
        foreach my $regex (@{$self->get_conf('TOOLCHAIN_REGEX')}) {
	    if ($name =~ m,^$regex, && defined($status->{$name}->{'Version'})) {
		$self->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	    }
	}
    }
    $self->log("\n");

    $self->log("Package versions:");
    foreach my $name (sort keys %{$status}) {
	if (defined($status->{$name}->{'Version'})) {
	    $self->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	}
    }
    $self->log("\n");

    return $status->{'dpkg-dev'}->{'Version'};
}

sub run_apt {
    my $self = shift;
    my $mode = shift;
    my $inst_ret = shift;
    my $rem_ret = shift;
    my $action = shift;
    my @packages = @_;
    my( $msgs, $status, $pkgs, $rpkgs );

    $msgs = "";
    # redirection of stdin from /dev/null so that conffile question
    # are treated as if RETURN was pressed.
    # dpkg since 1.4.1.18 issues an error on the conffile question if
    # it reads EOF -- hardwire the new --force-confold option to avoid
    # the questions.
    my @apt_command = ($self->get_conf('APT_GET'), '--purge',
	'-o', 'DPkg::Options::=--force-confold',
	'-o', 'DPkg::Options::=--refuse-remove-essential',
	'-o', 'APT::Install-Recommends=false',
	'-o', 'Dpkg::Use-Pty=false',
	'-q');
    push @apt_command, '--allow-unauthenticated' if
	($self->get_conf('APT_ALLOW_UNAUTHENTICATED'));
    if ( $self->get('Host Arch') ne $self->get('Build Arch') ) {
	# drop m-a:foreign and essential:yes packages that are not arch:all
	# and not arch:native
	push @apt_command, '--solver', 'sbuild-cross-resolver';
    }
    push @apt_command, "$mode", $action, @packages;
    my $pipe =
	$self->pipe_apt_command(
	    { COMMAND => \@apt_command,
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });
    if (!$pipe) {
	$self->log("Can't open pipe to apt-get: $!\n");
	return 0;
    }

    while(<$pipe>) {
	$msgs .= $_;
	$self->log($_) if $mode ne "-s" || debug($_);
    }
    close($pipe);
    $status = $?;

    $pkgs = $rpkgs = "";
    if ($msgs =~ /NEW packages will be installed:\n((^[ 	].*\n)*)/mi) {
	($pkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$pkgs =~ s/\*//g;
    }
    if ($msgs =~ /packages will be REMOVED:\n((^[ 	].*\n)*)/mi) {
	($rpkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$rpkgs =~ s/\*//g;
    }
    @$inst_ret = split( /\s+/, $pkgs );
    @$rem_ret = split( /\s+/, $rpkgs );

    $self->log("apt-get failed.\n") if $status && $mode ne "-s";
    return $mode eq "-s" || $status == 0;
}

sub run_xapt {
    my $self = shift;
    my $mode = shift;
    my $inst_ret = shift;
    my $rem_ret = shift;
    my $action = shift;
    my @packages = @_;
    my( $msgs, $status, $pkgs, $rpkgs );

    $msgs = "";
    # redirection of stdin from /dev/null so that conffile question
    # are treated as if RETURN was pressed.
    # dpkg since 1.4.1.18 issues an error on the conffile question if
    # it reads EOF -- hardwire the new --force-confold option to avoid
    # the questions.
    my @xapt_command = ($self->get_conf('XAPT'));
    my $pipe =
	$self->pipe_xapt_command(
	    { COMMAND => \@xapt_command,
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });
    if (!$pipe) {
	$self->log("Can't open pipe to xapt: $!\n");
	return 0;
    }

    while(<$pipe>) {
	$msgs .= $_;
	$self->log($_) if $mode ne "-s" || debug($_);
    }
    close($pipe);
    $status = $?;

    $pkgs = $rpkgs = "";
    if ($msgs =~ /NEW packages will be installed:\n((^[ 	].*\n)*)/mi) {
	($pkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$pkgs =~ s/\*//g;
    }
    if ($msgs =~ /packages will be REMOVED:\n((^[ 	].*\n)*)/mi) {
	($rpkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$rpkgs =~ s/\*//g;
    }
    @$inst_ret = split( /\s+/, $pkgs );
    @$rem_ret = split( /\s+/, $rpkgs );

    $self->log("xapt failed.\n") if $status && $mode ne "-s";
    return $mode eq "-s" || $status == 0;
}

sub format_deps {
    my $self = shift;

    return join( ", ",
		 map { join( "|",
			     map { ($_->{'Neg'} ? "!" : "") .
				       $_->{'Package'} .
				       ($_->{'Rel'} ? " ($_->{'Rel'} $_->{'Version'})":"")}
			     scalar($_), @{$_->{'Alternatives'}}) } @_ );
}

sub get_dpkg_status {
    my $self = shift;
    my @interest = @_;
    my %result;

    debug("Requesting dpkg status for packages: @interest\n");
    my $STATUS = $self->get('Session')->get_read_file_handle('/var/lib/dpkg/status');
    if (!$STATUS) {
	$self->log("Can't open /var/lib/dpkg/status inside chroot: $!\n");
	return ();
    }
    local( $/ ) = "";
    while( <$STATUS> ) {
	my( $pkg, $status, $version, $provides );
	/^Package:\s*(.*)\s*$/mi and $pkg = $1;
	/^Status:\s*(.*)\s*$/mi and $status = $1;
	/^Version:\s*(.*)\s*$/mi and $version = $1;
	/^Provides:\s*(.*)\s*$/mi and $provides = $1;
	if (!$pkg) {
	    $self->log_error("parse error in /var/lib/dpkg/status: no Package: field\n");
	    next;
	}
	if (defined($version)) {
	    debug("$pkg ($version) status: $status\n") if $self->get_conf('DEBUG') >= 2;
	} else {
	    debug("$pkg status: $status\n") if $self->get_conf('DEBUG') >= 2;
	}
	if (!$status) {
	    $self->log_error("parse error in /var/lib/dpkg/status: no Status: field for package $pkg\n");
	    next;
	}
	if ($status !~ /\sinstalled$/) {
	    $result{$pkg}->{'Installed'} = 0
		if !(exists($result{$pkg}) &&
		     $result{$pkg}->{'Version'} eq '~*=PROVIDED=*=');
	    next;
	}
	if (!defined $version || $version eq "") {
	    $self->log_error("parse error in /var/lib/dpkg/status: no Version: field for package $pkg\n");
	    next;
	}
	$result{$pkg} = { Installed => 1, Version => $version }
	    if (isin( $pkg, @interest ) || !@interest);
	if ($provides) {
	    foreach (split( /\s*,\s*/, $provides )) {
		$result{$_} = { Installed => 1, Version => '~*=PROVIDED=*=' }
		if isin( $_, @interest ) and (not exists($result{$_}) or
					      ($result{$_}->{'Installed'} == 0));
	    }
	}
    }
    close( $STATUS );
    return \%result;
}

# Create an apt archive. Add to it if one exists.
sub setup_apt_archive {
    my $self = shift;
    my $dummy_pkg_name = shift;
    my @pkgs = @_;

    my $session = $self->get('Session');


    if (!$session->chown($self->get('Dummy package path'), $self->get_conf('BUILD_USER'), 'sbuild')) {
	$self->log_error("Failed to set " . $self->get_conf('BUILD_USER') .
			 ":sbuild ownership on dummy package dir\n");
	return 0;
    }
    if (!$session->chmod($self->get('Dummy package path'), '0770')) {
	$self->log_error("Failed to set 0770 permissions on dummy package dir\n");
	return 0;
    }
    my $dummy_dir = $self->get('Dummy package path');
    my $dummy_gpghome = $dummy_dir . '/gpg';
    my $dummy_archive_dir = $dummy_dir . '/apt_archive';
    my $dummy_release_file = $dummy_archive_dir . '/Release';
    my $dummy_archive_seckey = $dummy_archive_dir . '/sbuild-key.sec';
    my $dummy_archive_pubkey = $dummy_archive_dir . '/sbuild-key.pub';

    $self->set('Dummy archive directory', $dummy_archive_dir);
    $self->set('Dummy Release file', $dummy_release_file);
    my $dummy_archive_list_file = $self->get('Dummy archive list file');

    if (!$session->test_directory($dummy_dir)) {
        $self->log_warning('Could not create build-depends dummy dir ' . $dummy_dir . ': ' . $!);
        return 0;
    }
    if (!($session->test_directory($dummy_gpghome) || $session->mkdir($dummy_gpghome, { MODE => "00700"}))) {
        $self->log_warning('Could not create build-depends dummy gpg home dir ' . $dummy_gpghome . ': ' . $!);
        return 0;
    }
    if (!$session->chown($dummy_gpghome, $self->get_conf('BUILD_USER'), 'sbuild')) {
	$self->log_error('Failed to set ' . $self->get_conf('BUILD_USER') .
			 ':sbuild ownership on $dummy_gpghome\n');
	return 0;
    }
    if (!($session->test_directory($dummy_archive_dir) || $session->mkdir($dummy_archive_dir, { MODE => "00775"}))) {
        $self->log_warning('Could not create build-depends dummy archive dir ' . $dummy_archive_dir . ': ' . $!);
        return 0;
    }

    my $dummy_pkg_dir = $dummy_dir . '/' . $dummy_pkg_name;
    my $dummy_deb = $dummy_archive_dir . '/' . $dummy_pkg_name . '.deb';
    my $dummy_dsc = $dummy_archive_dir . '/' . $dummy_pkg_name . '.dsc';

    if (!($session->mkdir("$dummy_pkg_dir", { MODE => "00775"}))) {
	$self->log_warning('Could not create build-depends dummy dir ' . $dummy_pkg_dir . $!);
	return 0;
    }

    if (!($session->mkdir("$dummy_pkg_dir/DEBIAN", { MODE => "00775"}))) {
	$self->log_warning('Could not create build-depends dummy dir ' . $dummy_pkg_dir . '/DEBIAN: ' . $!);
	return 0;
    }

    my $DUMMY_CONTROL = $session->get_write_file_handle("$dummy_pkg_dir/DEBIAN/control");
    if (!$DUMMY_CONTROL) {
	$self->log_warning('Could not open ' . $dummy_pkg_dir . '/DEBIAN/control for writing: ' . $!);
	return 0;
    }

    my $arch = $self->get('Host Arch');
    print $DUMMY_CONTROL <<"EOF";
Package: $dummy_pkg_name
Version: 0.invalid.0
Architecture: $arch
EOF

    my @positive;
    my @negative;
    my @positive_arch;
    my @negative_arch;
    my @positive_indep;
    my @negative_indep;

    for my $pkg (@pkgs) {
	my $deps = $self->get('AptDependencies')->{$pkg};

	push(@positive, $deps->{'Build Depends'})
	    if (defined($deps->{'Build Depends'}) &&
		$deps->{'Build Depends'} ne "");
	push(@negative, $deps->{'Build Conflicts'})
	    if (defined($deps->{'Build Conflicts'}) &&
		$deps->{'Build Conflicts'} ne "");
	if ($self->get_conf('BUILD_ARCH_ANY')) {
	    push(@positive_arch, $deps->{'Build Depends Arch'})
		if (defined($deps->{'Build Depends Arch'}) &&
		    $deps->{'Build Depends Arch'} ne "");
	    push(@negative_arch, $deps->{'Build Conflicts Arch'})
		if (defined($deps->{'Build Conflicts Arch'}) &&
		    $deps->{'Build Conflicts Arch'} ne "");
	}
	if ($self->get_conf('BUILD_ARCH_ALL')) {
	    push(@positive_indep, $deps->{'Build Depends Indep'})
		if (defined($deps->{'Build Depends Indep'}) &&
		    $deps->{'Build Depends Indep'} ne "");
	    push(@negative_indep, $deps->{'Build Conflicts Indep'})
		if (defined($deps->{'Build Conflicts Indep'}) &&
		    $deps->{'Build Conflicts Indep'} ne "");
	}
    }

    my $positive_build_deps = join(", ", @positive,
				   @positive_arch, @positive_indep);
    my $positive = deps_parse($positive_build_deps,
			      reduce_arch => 1,
			      host_arch => $self->get('Host Arch'),
			      build_arch => $self->get('Build Arch'),
			      build_dep => 1,
			      reduce_profiles => 1,
			      build_profiles => [ split / /, $self->get('Build Profiles') ]);
    if( !defined $positive ) {
        my $msg = "Error! deps_parse() couldn't parse the positive Build-Depends '$positive_build_deps'";
        $self->log_error("$msg\n");
        return 0;
    }

    my $negative_build_deps = join(", ", @negative,
				   @negative_arch, @negative_indep);
    my $negative = deps_parse($negative_build_deps,
			      reduce_arch => 1,
			      host_arch => $self->get('Host Arch'),
			      build_arch => $self->get('Build Arch'),
			      build_dep => 1,
			      union => 1,
			      reduce_profiles => 1,
			      build_profiles => [ split / /, $self->get('Build Profiles') ]);
    if( !defined $negative ) {
        my $msg = "Error! deps_parse() couldn't parse the negative Build-Depends '$negative_build_deps'";
        $self->log_error("$msg\n");
        return 0;
    }


    # sbuild turns build dependencies into the dependencies of a dummy binary
    # package. Since binary package dependencies do not support :native the
    # architecture qualifier, these have to either be removed during native
    # compilation or replaced by the build (native) architecture during cross
    # building
    my $handle_native_archqual = sub {
        my ($dep) = @_;
        if ($dep->{archqual} && $dep->{archqual} eq "native") {
            if ($self->get('Host Arch') eq $self->get('Build Arch')) {
                $dep->{archqual} = undef;
            } else {
                $dep->{archqual} = $self->get('Build Arch');
            }
        }
        return 1;
    };
    deps_iterate($positive, $handle_native_archqual);
    deps_iterate($negative, $handle_native_archqual);

    $self->log("Merged Build-Depends: $positive\n") if $positive;
    $self->log("Merged Build-Conflicts: $negative\n") if $negative;

    # Filter out all but the first alternative except in special
    # cases.
    if (!$self->get_conf('RESOLVE_ALTERNATIVES')) {
	my $positive_filtered = Dpkg::Deps::AND->new();
	foreach my $item ($positive->get_deps()) {
	    my $alt_filtered = Dpkg::Deps::OR->new();
	    my @alternatives = $item->get_deps();
	    my $first = shift @alternatives;
	    $alt_filtered->add($first) if defined $first;
	    # Allow foo (rel x) | foo (rel y) as the only acceptable
	    # form of alternative.  i.e. where the package is the
	    # same, but different relations are needed, since these
	    # are effectively a single logical dependency.
	    foreach my $alt (@alternatives) {
		if ($first->{'package'} eq $alt->{'package'}) {
		    $alt_filtered->add($alt);
		} else {
		    last;
		}
	    }
	    $positive_filtered->add($alt_filtered);
	}
	$positive = $positive_filtered;
    }

    if ($positive ne "") {
	print $DUMMY_CONTROL 'Depends: ' . $positive . "\n";
    }
    if ($negative ne "") {
	print $DUMMY_CONTROL 'Conflicts: ' . $negative . "\n";
    }

    $self->log("Filtered Build-Depends: $positive\n") if $positive;
    $self->log("Filtered Build-Conflicts: $negative\n") if $negative;

    print $DUMMY_CONTROL <<"EOF";
Maintainer: Debian buildd-tools Developers <buildd-tools-devel\@lists.alioth.debian.org>
Description: Dummy package to satisfy dependencies with apt - created by sbuild
 This package was created automatically by sbuild and should never appear on
 a real system. You can safely remove it.
EOF
    close ($DUMMY_CONTROL);

    foreach my $path ($dummy_pkg_dir . '/DEBIAN/control',
		      $dummy_pkg_dir . '/DEBIAN',
		      $dummy_pkg_dir,
		      $dummy_archive_dir) {
	if (!$session->chown($path, $self->get_conf('BUILD_USER'), 'sbuild')) {
	    $self->log_error("Failed to set " . $self->get_conf('BUILD_USER')
			   . ":sbuild ownership on $path\n");
	    return 0;
	}
    }

    # Now build the package:
    # NO_PKG_MANGLE=1 disables https://launchpad.net/pkgbinarymangler (only used on Ubuntu)
    $session->run_command(
	{ COMMAND => ['env', 'NO_PKG_MANGLE=1', 'dpkg-deb', '--build', $dummy_pkg_dir, $dummy_deb],
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0});
    if ($?) {
	$self->log("Dummy package creation failed\n");
	return 0;
    }

    # Write the dummy dsc file.
    my $dummy_dsc_fh = $session->get_write_file_handle($dummy_dsc);
    if (!$dummy_dsc_fh) {
        $self->log_warning('Could not open ' . $dummy_dsc . ' for writing: ' . $!);
        return 0;
    }

    print $dummy_dsc_fh <<"EOF";
Format: 1.0
Source: $dummy_pkg_name
Binary: $dummy_pkg_name
Architecture: any
Version: 0.invalid.0
Maintainer: Debian buildd-tools Developers <buildd-tools-devel\@lists.alioth.debian.org>
EOF
    if (scalar(@positive)) {
       print $dummy_dsc_fh 'Build-Depends: ' . join(", ", @positive) . "\n";
    }
    if (scalar(@negative)) {
       print $dummy_dsc_fh 'Build-Conflicts: ' . join(", ", @negative) . "\n";
    }
    if (scalar(@positive_arch)) {
       print $dummy_dsc_fh 'Build-Depends-Arch: ' . join(", ", @positive_arch) . "\n";
    }
    if (scalar(@negative_arch)) {
       print $dummy_dsc_fh 'Build-Conflicts-Arch: ' . join(", ", @negative_arch) . "\n";
    }
    if (scalar(@positive_indep)) {
       print $dummy_dsc_fh 'Build-Depends-Indep: ' . join(", ", @positive_indep) . "\n";
    }
    if (scalar(@negative_indep)) {
       print $dummy_dsc_fh 'Build-Conflicts-Indep: ' . join(", ", @negative_indep) . "\n";
    }
    print $dummy_dsc_fh "\n";
    close $dummy_dsc_fh;

    # Do code to run apt-ftparchive
    if (!$self->run_apt_ftparchive($self->get('Dummy archive directory'))) {
        $self->log("Failed to run apt-ftparchive.\n");
        return 0;
    }

    # Write a list file for the dummy archive if one not create yet.
    if (!$session->test_regular_file($dummy_archive_list_file)) {
	my $tmpfilename = $session->mktemp();

	if (!$tmpfilename) {
	    $self->log_error("Can't create tempfile\n");
	    return 0;
	}

	my $tmpfh = $session->get_write_file_handle($tmpfilename);
	if (!$tmpfh) {
	    $self->log_error("Cannot open pipe: $!\n");
	    return 0;
	}

	# We always trust the dummy apt repositories by setting trusted=yes.
	#
	# We use copy:// instead of file:// as URI because the latter will make
	# apt use symlinks in /var/lib/apt/lists. These symlinks will become
	# broken after the dummy archive is removed. This in turn confuses
	# launchpad-buildd which directly tries to access
	# /var/lib/apt/lists/*_Packages and cannot use `apt-get indextargets` as
	# that apt feature is too new for it.
        print $tmpfh 'deb [trusted=yes] copy://' . $dummy_archive_dir . " ./\n";
        print $tmpfh 'deb-src [trusted=yes] copy://' . $dummy_archive_dir . " ./\n";

        close($tmpfh);
        # List file needs to be moved with root.
        if (!$session->chmod($tmpfilename, '0644')) {
            $self->log("Failed to create apt list file for dummy archive.\n");
	    $session->unlink($tmpfilename);
            return 0;
        }
        if (!$session->rename($tmpfilename, $dummy_archive_list_file)) {
            $self->log("Failed to create apt list file for dummy archive.\n");
	    $session->unlink($tmpfilename);
            return 0;
        }
    }

    return 1;
}

# Remove the apt archive.
sub cleanup_apt_archive {
    my $self = shift;

    my $session = $self->get('Session');

    if (defined $self->get('Dummy package path')) {
	$session->unlink($self->get('Dummy package path'), { RECURSIVE => 1, FORCE => 1 });
    }

    if (defined $self->get('Extra packages path')) {
	$session->unlink($self->get('Extra packages path'), { RECURSIVE => 1, FORCE => 1 });
    }

    $session->unlink($self->get('Dummy archive list file'), { FORCE => 1 });

    $session->unlink($self->get('Extra repositories archive list file'), { FORCE => 1 });

    $session->unlink($self->get('Extra packages archive list file'), { FORCE => 1 });

    $self->set('Extra packages path', undef);
    $self->set('Extra packages archive directory', undef);
    $self->set('Extra packages release file', undef);
    $self->set('Dummy archive directory', undef);
    $self->set('Dummy Release file', undef);
}

# Function that runs apt-ftparchive
sub run_apt_ftparchive {
    my $self = shift;
    my $dummy_archive_dir = shift;

    my $session = $self->get('Session');

    # We create the Packages, Sources and Release file inside the chroot.
    # We cannot use Digest::MD5, or Digest::SHA because
    # they are not available inside a chroot with only Essential:yes and apt
    # installed.
    # We cannot use apt-ftparchive as this is not available inside the chroot.
    # Apt-ftparchive outside the chroot might not have access to the files
    # inside the chroot (for example when using qemu or ssh backends).
    # The only alternative would've been to set up the archive outside the
    # chroot using apt-ftparchive and to then copy Packages, Sources and
    # Release into the chroot.
    # We do not do this to avoid copying files from and to the chroot.
    # At the same time doing it like this has the advantage to have less
    # dependencies of sbuild itself (no apt-ftparchive needed).
    # The disadvantage of doing it this way is that we now have to maintain
    # our own code creating the Release file which might break in the future.
    my $packagessourcescmd = <<'SCRIPTEND';
use strict;
use warnings;

use POSIX qw(strftime);
use POSIX qw(locale_h);

# Execute a command without /bin/sh but plain execvp while redirecting its
# standard output to a file given as the first argument.
# Using "print $fh `my_command`" has the disadvantage that "my_command" might
# be executed through /bin/sh (depending on the characters used) or that the
# output of "my_command" is very long.

sub hash_file($$)
{
	my ($filename, $util) = @_;
	my $output = `$util $filename`;
	my ($hash, undef) = split /\s+/, $output;
	return $hash;
}

{
    opendir(my $dh, '.') or die "Can't opendir('.'): $!";
    open my $out, '>', 'Packages';
    while (my $entry = readdir $dh) {
	next if $entry !~ /\.deb$/;
	open my $in, '-|', 'dpkg-deb', '-I', $entry, 'control' or die "cannot fork dpkg-deb";
	while (my $line = <$in>) {
	    print $out $line;
	}
	close $in;
	my $size = -s $entry;
	my $md5 = hash_file($entry, 'md5sum');
	my $sha1 = hash_file($entry, 'sha1sum');
	my $sha256 = hash_file($entry, 'sha256sum');
	print $out "Size: $size\n";
	print $out "MD5sum: $md5\n";
	print $out "SHA1: $sha1\n";
	print $out "SHA256: $sha256\n";
	print $out "Filename: ./$entry\n";
	print $out "\n";
    }
    close $out;
    closedir($dh);
}
{
    opendir(my $dh, '.') or die "Can't opendir('.'): $!";
    open my $out, '>', 'Sources';
    while (my $entry = readdir $dh) {
	next if $entry !~ /\.dsc$/;
	my $size = -s $entry;
	my $md5 = hash_file($entry, 'md5sum');
	my $sha1 = hash_file($entry, 'sha1sum');
	my $sha256 = hash_file($entry, 'sha256sum');
	my ($sha1_printed, $sha256_printed, $files_printed) = (0, 0, 0);
	open my $in, '<', $entry or die "cannot open $entry";
	while (my $line = <$in>) {
	    next if $line eq "\n";
	    $line =~ s/^Source:/Package:/;
	    print $out $line;
	    if ($line eq "Checksums-Sha1:\n") {
		print $out " $sha1 $size $entry\n";
		$sha1_printed = 1;
	    } elsif ($line eq "Checksums-Sha256:\n") {
		print $out " $sha256 $size $entry\n";
		$sha256_printed = 1;
	    } elsif ($line eq "Files:\n") {
		print $out " $md5 $size $entry\n";
		$files_printed = 1;
	    }
	}
	close $in;
	if ($sha1_printed == 0) {
	    print $out "Checksums-Sha1:\n";
	    print $out " $sha1 $size $entry\n";
	}
	if ($sha256_printed == 0) {
	    print $out "Checksums-Sha256:\n";
	    print $out " $sha256 $size $entry\n";
	}
	if ($files_printed == 0) {
	    print $out "Files:\n";
	    print $out " $md5 $size $entry\n";
	}
	print $out "Directory: .\n";
	print $out "\n";
    }
    close $out;
    closedir($dh);
}

my $packages_md5 = hash_file('Packages', 'md5sum');
my $sources_md5 = hash_file('Sources', 'md5sum');

my $packages_sha1 = hash_file('Packages', 'sha1sum');
my $sources_sha1 = hash_file('Sources', 'sha1sum');

my $packages_sha256 = hash_file('Packages', 'sha256sum');
my $sources_sha256 = hash_file('Sources', 'sha256sum');

my $packages_size = -s 'Packages';
my $sources_size = -s 'Sources';

# The timestamp format of release files is documented here:
#   https://wiki.debian.org/RepositoryFormat#Date.2CValid-Until
# It is specified to be the same format as described in Debian Policy §4.4
#   https://www.debian.org/doc/debian-policy/ch-source.html#s-dpkgchangelog
# or the same as in debian/changelog or the Date field in .changes files.
# or the same format as `date -R`
# To adhere to the specified format, the C or C.UTF-8 locale must be used.
my $old_locale = setlocale(LC_TIME);
setlocale(LC_TIME, "C.UTF-8");
my $datestring = strftime "%a, %d %b %Y %H:%M:%S +0000", gmtime();
setlocale(LC_TIME, $old_locale);

open(my $releasefh, '>', 'Release') or die "cannot open Release for writing: $!";

print $releasefh <<"END";
Codename: invalid-sbuild-codename
Date: $datestring
Description: Sbuild Build Dependency Temporary Archive
Label: sbuild-build-depends-archive
Origin: sbuild-build-depends-archive
Suite: invalid-sbuild-suite
MD5Sum:
 $packages_md5 $packages_size Packages
 $sources_md5 $sources_size Sources
SHA1:
 $packages_sha1 $packages_size Packages
 $sources_sha1 $sources_size Sources
SHA256:
 $packages_sha256 $packages_size Packages
 $sources_sha256 $sources_size Sources
END

close $releasefh;

SCRIPTEND

    # Instead of using $(perl -e) and passing $packagessourcescmd as a command
    # line argument, feed perl from standard input because otherwise the
    # command line will be too long for certain backends (like the autopkgtest
    # qemu backend).
    my $pipe = $session->pipe_command(
	{ COMMAND => ['perl'],
	    USER => "root",
	    DIR => $dummy_archive_dir,
	    PIPE => 'out',
	});
    if (!$pipe) {
	$self->log_error("cannot open pipe\n");
	return 0;
    }
    print $pipe $packagessourcescmd;
    close $pipe;
    if ($? ne 0) {
	$self->log_error("cannot create dummy archive\n");
	return 0;
    }

    return 1;
}

sub get_apt_command_internal {
    my $self = shift;
    my $options = shift;

    my $command = $options->{'COMMAND'};
    my $apt_options = $self->get('APT Options');

    debug2("APT Options: ", join(" ", @$apt_options), "\n")
	if defined($apt_options);

    my @aptcommand = ();
    if (defined($apt_options)) {
	push(@aptcommand, @{$command}[0]);
	push(@aptcommand, @$apt_options);
	if ($#$command > 0) {
	    push(@aptcommand, @{$command}[1 .. $#$command]);
	}
    } else {
	@aptcommand = @$command;
    }

    debug2("APT Command: ", join(" ", @aptcommand), "\n");

    $options->{'INTCOMMAND'} = \@aptcommand;
}

sub run_apt_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_apt_command_internal($options);

    if ($self->get('Split')) {
	return $host->run_command_internal($options);
    } else {
	return $session->run_command_internal($options);
    }
}

sub pipe_apt_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_apt_command_internal($options);

    if ($self->get('Split')) {
	return $host->pipe_command_internal($options);
    } else {
	return $session->pipe_command_internal($options);
    }
}

sub pipe_xapt_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_apt_command_internal($options);

    if ($self->get('Split')) {
	return $host->pipe_command_internal($options);
    } else {
	return $session->pipe_command_internal($options);
    }
}

sub get_aptitude_command_internal {
    my $self = shift;
    my $options = shift;

    my $command = $options->{'COMMAND'};
    my $apt_options = $self->get('Aptitude Options');

    debug2("Aptitude Options: ", join(" ", @$apt_options), "\n")
	if defined($apt_options);

    my @aptcommand = ();
    if (defined($apt_options)) {
	push(@aptcommand, @{$command}[0]);
	push(@aptcommand, @$apt_options);
	if ($#$command > 0) {
	    push(@aptcommand, @{$command}[1 .. $#$command]);
	}
    } else {
	@aptcommand = @$command;
    }

    debug2("APT Command: ", join(" ", @aptcommand), "\n");

    $options->{'INTCOMMAND'} = \@aptcommand;
}

sub run_aptitude_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_aptitude_command_internal($options);

    if ($self->get('Split')) {
	return $host->run_command_internal($options);
    } else {
	return $session->run_command_internal($options);
    }
}

sub pipe_aptitude_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_aptitude_command_internal($options);

    if ($self->get('Split')) {
	return $host->pipe_command_internal($options);
    } else {
	return $session->pipe_command_internal($options);
    }
}

sub get_sbuild_dummy_pkg_name {
    my $self = shift;
    my $name = shift;

    return 'sbuild-build-depends-' . $name. '-dummy';
}

1;
