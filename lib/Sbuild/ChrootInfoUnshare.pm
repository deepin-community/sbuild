#
# ChrootInfoUnshare.pm: chroot utility library for sbuild
# Copyright © 2018      Johannes Schauer Marin Rodrigues <josch@debian.org>
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

package Sbuild::ChrootInfoUnshare;

use Sbuild::ChrootInfo;
use Sbuild::ChrootUnshare;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ChrootInfo);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    return $self;
}

sub get_info_all {
    my $self = shift;

    my $chroots = {};

    my $xdg_cache_home = $ENV{'HOME'} . "/.cache/sbuild";
    if (defined($ENV{'XDG_CACHE_HOME'})) {
	$xdg_cache_home = $ENV{'XDG_CACHE_HOME'} . '/sbuild';
    }

    my $num_found = 0;
    if (opendir my $dh, $xdg_cache_home) {
	while (defined(my $file = readdir $dh)) {
	    next if $file eq '.' || $file eq '..';
	    next if $file !~ /^[^-]+-[^-]+(-[^-]+)?(-sbuild)?\.t.+$/;
	    my $isdir = -d "$xdg_cache_home/$file";
	    $file =~ s/\.t.+$//; # chop off extension
	    if (! $isdir) {
		$chroots->{'chroot'}->{$file} = 1;
	    }
	    $chroots->{'source'}->{$file} = 1;
	    $num_found += 1;
	}
	closedir $dh;
    }

    if ($num_found == 0) {
	print STDERR "I: No tarballs found in $xdg_cache_home\n";
    }

    $self->set('Chroots', $chroots);
}

sub _create {
    my $self = shift;
    my $chroot_id = shift;

    my $chroot = undef;

    if (defined($chroot_id)) {
	$chroot = Sbuild::ChrootUnshare->new($self->get('Config'), $chroot_id);
    }

    return $chroot;
}

1;
