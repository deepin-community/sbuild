#
# ChrootInfo.pm: chroot utility library for sbuild
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootInfo;

use strict;
use warnings;

use Sbuild::Base;

use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Chroots', {});

    $self->get_info_all();

    return $self;
}



sub create {
    my $self = shift;
    my $namespace = shift;
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift; # this is the build arch

    my $chrootid = $self->find($namespace, $distribution, $chroot, $arch);

    my $newchroot = $self->_create($chrootid);

    if (defined($newchroot)) {
	$newchroot->set('Chroots', $self);
    }

    return $newchroot;
}


sub find {
    my $self = shift;
    my $namespace = shift;
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift; # this is the build arch

    # Use namespace given from $distribution if one is found
    if ($distribution =~ /^([^:]+):/msx) {
	$namespace = $1;
	$distribution =~ s/^[^:]+://msx;
    }

    my $chroots = $self->get('Chroots');

    # Don't do strict arch checking if ARCH == HOST_ARCH.
    if (!defined($arch) || $arch eq "") {
	$arch = $self->get_conf('BUILD_ARCH');
    }
    my $host_arch = $self->get_conf('HOST_ARCH');

    if (!defined $chroot) {
	my $ns = $chroots->{$namespace};
	if (!defined($ns)) {
	    if ($namespace ne 'chroot') {
		$chroot = $self->find('chroot', $distribution, $chroot, $arch);
	    } else {
		return undef;
	    }
	}

        if ($arch ne $host_arch &&
            defined($ns->{"${distribution}-${arch}-${host_arch}-sbuild"})) {
            $chroot = "${namespace}:${distribution}-${arch}-${host_arch}-sbuild";
        }
        elsif ($arch ne $host_arch &&
            defined($ns->{"${distribution}-${arch}-${host_arch}"})) {
            $chroot = "${namespace}:${distribution}-${arch}-${host_arch}";
        }
        elsif ($arch ne "" &&
            defined($ns->{"${distribution}-${arch}-sbuild"})) {
            $chroot = "${namespace}:${distribution}-${arch}-sbuild";
        }
        elsif (defined($ns->{"${distribution}-sbuild"})) {
            $chroot = "${namespace}:${distribution}-sbuild";
        }
        elsif ($arch ne "" &&
               defined($ns->{"${distribution}-${arch}"})) {
            $chroot = "${namespace}:${distribution}-${arch}";
        } elsif (defined($ns->{$distribution})) {
            $chroot = "${namespace}:${distribution}";
	}
    }

    if (!$chroot) {
	# Fall back to chroot namespace.
	if ($namespace ne 'chroot') {
	    $chroot = $self->find('chroot', $distribution, $chroot, $arch);
	} else {
		$self->log_error("Chroot for distribution $distribution, architecture $arch not found\n");
		return undef;
	}
    }

    return $chroot;
}

1;
