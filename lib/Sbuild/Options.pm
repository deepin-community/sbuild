#
# Options.pm: options parser for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Options;

use strict;
use warnings;

use Sbuild::OptionsBase;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::OptionsBase);

    @EXPORT = qw();
}

sub set_options {
    my $self = shift;

    my ($opt_arch_all, $opt_no_arch_all);
    my ($opt_build_arch, $opt_host_arch, $opt_arch);
    my ($opt_arch_any, $opt_no_arch_any);
    my ($opt_source, $opt_no_source);
    my ($opt_apt_clean, $opt_no_apt_clean, $opt_apt_update, $opt_no_apt_update,
	$opt_apt_upgrade, $opt_no_apt_upgrade, $opt_apt_distupgrade, $opt_no_apt_distupgrade);
    my ($opt_purge, $opt_purge_build, $opt_purge_deps, $opt_purge_session);
    my ($opt_resolve_alternatives, $opt_no_resolve_alternatives);
    my ($opt_clean_source, $opt_no_clean_source);
    my ($opt_run_lintian, $opt_no_run_lintian);
    my ($opt_run_piuparts, $opt_no_run_piuparts);
    my ($opt_run_autopkgtest, $opt_no_run_autopkgtest);
    my ($opt_make_binnmu, $opt_binnmu, $opt_binnmu_timestamp, $opt_binnmu_changelog, $opt_append_to_version);

    $self->add_options("arch=s" => sub {
			   if (defined $opt_arch && $opt_arch ne $_[1]) {
			       die "cannot specify differing --arch multiple times";
			   }
			   if (defined $opt_build_arch && $opt_build_arch ne $_[1]) {
			       die "cannot specify --arch together with differing --build-arch";
			   }
			   if (defined $opt_host_arch && $opt_host_arch ne $_[1]) {
			       die "cannot specify --arch together with differing --host-arch";
			   }
			   $self->set_conf('HOST_ARCH', $_[1]);
			   $self->set_conf('BUILD_ARCH', $_[1]);
			   $opt_arch = $_[1];
		       },
		       "build=s" => sub {
			   if (defined $opt_build_arch && $opt_build_arch ne $_[1]) {
			       die "cannot specify differing --build-arch multiple times";
			   }
			   if (defined $opt_arch && $opt_arch ne $_[1]) {
			       die "cannot specify --build-arch together with differing --arch";
			   }
			   $self->set_conf('BUILD_ARCH', $_[1]);
			   $opt_build_arch = $_[1];
		       },
		       "host=s" => sub {
			   if (defined $opt_host_arch && $opt_host_arch ne $_[1]) {
			       die "cannot specify differing --host-arch multiple times";
			   }
			   if (defined $opt_arch && $opt_arch ne $_[1]) {
			       die "cannot specify --host-arch together with differing --arch";
			   }
			   $self->set_conf('HOST_ARCH', $_[1]);
			   $opt_host_arch = $_[1];
		       },
		       "A|arch-all" => sub {
			   if ($opt_no_arch_all) {
			       die "--arch-all cannot be used together with --no-arch-all";
			   }
			   if ($opt_make_binnmu) {
			       die "--arch-all cannot be used together with --make-binNMU";
			   }
			   if ($opt_append_to_version) {
			       die "--arch-all cannot be used together with --append-to-version";
			   }
			   $self->set_conf('BUILD_ARCH_ALL', 1);
			   $opt_arch_all = 1;
		       },
		       "no-arch-all" => sub {
			   if ($opt_arch_all) {
			       die "--no-arch-all cannot be used together with --arch-all";
			   }
			   $self->set_conf('BUILD_ARCH_ALL', 0);
			   $opt_no_arch_all = 1;
		       },
		       "arch-any" => sub {
			   if ($opt_no_arch_any) {
			       die "--arch-any cannot be used together with --no-arch-any";
			   }
			   $self->set_conf('BUILD_ARCH_ANY', 1);
			   $opt_arch_any = 1;
		       },
		       "no-arch-any" => sub {
			   if ($opt_arch_any) {
			       die "--no-arch-any cannot be used together with --arch-any";
			   }
			   $self->set_conf('BUILD_ARCH_ANY', 0);
			   $opt_no_arch_any = 1;
		       },
		       "profiles=s" => sub {
			   $_[1] =~ tr/,/ /;
			   $self->set_conf('BUILD_PROFILES', $_[1]);
		       },
		       "add-depends=s" => sub {
			   push(@{$self->get_conf('MANUAL_DEPENDS')}, $_[1]);
		       },
		       "add-conflicts=s" => sub {
			   push(@{$self->get_conf('MANUAL_CONFLICTS')}, $_[1]);
		       },
		       "add-depends-arch=s" => sub {
			   push(@{$self->get_conf('MANUAL_DEPENDS_ARCH')}, $_[1]);
		       },
		       "add-conflicts-arch=s" => sub {
			   push(@{$self->get_conf('MANUAL_CONFLICTS_ARCH')}, $_[1]);
		       },
		       "add-depends-indep=s" => sub {
			   push(@{$self->get_conf('MANUAL_DEPENDS_INDEP')}, $_[1]);
		       },
		       "add-conflicts-indep=s" => sub {
			   push(@{$self->get_conf('MANUAL_CONFLICTS_INDEP')}, $_[1]);
		       },
		       "b|batch" => sub {
			   $self->set_conf('BATCH_MODE', 1);
		       },
		       "make-binNMU=s" => sub {
			   if ($opt_binnmu_changelog) {
			       die "--make-binNMU cannot be used together with --binNMU-changelog";
			   }
			   $self->set_conf('BIN_NMU', $_[1]);
			   $self->set_conf('BIN_NMU_VERSION', 1)
			       if (!defined $self->get_conf('BIN_NMU_VERSION'));
			   $opt_make_binnmu = 1;
			   $self->set_conf('BUILD_ARCH_ALL', 0);
		       },
		       "binNMU=i" => sub {
			   if ($opt_binnmu_changelog) {
			       die "--binNMU cannot be used together with --binNMU-changelog";
			   }
			   $self->set_conf('BIN_NMU_VERSION', $_[1]);
			   $opt_binnmu = 1;
		       },
		       "binNMU-timestamp=s" => sub {
			   if ($opt_binnmu_changelog) {
			       die "--binNMU-timestamp cannot be used together with --binNMU-changelog";
			   }
			   $self->set_conf('BIN_NMU_TIMESTAMP', $_[1]);
			   $opt_binnmu_timestamp = 1;
		       },
		       "append-to-version=s" => sub {
			   if ($opt_binnmu_changelog) {
			       die "--append-to-version cannot be used together with --binNMU-changelog";
			   }
			   $self->set_conf('APPEND_TO_VERSION', $_[1]);
			   $opt_append_to_version = 1;
			   $self->set_conf('BUILD_ARCH_ALL', 0);
		       },
		       "binNMU-changelog=s" => sub {
			   if ($opt_make_binnmu) {
			       die "--binNMU-changelog cannot be used together with --make-binNMU";
			   }
			   if ($opt_binnmu) {
			       die "--binNMU-changelog cannot be used together with --binNMU";
			   }
			   if ($opt_binnmu_timestamp) {
			       die "--binNMU-changelog cannot be used together with --binNMU-timestamp";
			   }
			   if ($opt_append_to_version) {
			       die "--binNMU-changelog cannot be used together with --append-to-version";
			   }
			   $self->set_conf('BIN_NMU_CHANGELOG', $_[1]);
			   $opt_binnmu_changelog = 1;
		       },
		       "build-dir=s" => sub {
			   $self->set_conf('BUILD_DIR', $_[1]);
		       },
		       "c|chroot=s" => sub {
			   $self->set_conf('CHROOT', $_[1]);
		       },
		       "chroot-mode=s" => sub {
			   $self->set_conf('CHROOT_MODE', $_[1]);
		       },
		       "autopkgtest-virt-server=s" => sub {
			   $self->set_conf('AUTOPKGTEST_VIRT_SERVER', $_[1]);
		       },
		       "autopkgtest-virt-server-opts=s" => sub {
			   push(@{$self->get_conf('AUTOPKGTEST_VIRT_SERVER_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "autopkgtest-virt-server-opt=s" => sub {
			   push(@{$self->get_conf('AUTOPKGTEST_VIRT_SERVER_OPTIONS')}, $_[1]);
		       },
		       "apt-clean" => sub {
			   if ($opt_no_apt_clean) {
			       die "--apt-clean cannot be used together with --no-apt-clean";
			   }
			   $self->set_conf('APT_CLEAN', 1);
			   $opt_apt_clean = 1;
		       },
		       "apt-update" => sub {
			   if ($opt_no_apt_update) {
			       die "--apt-update cannot be used together with --no-apt-update";
			   }
			   $self->set_conf('APT_UPDATE', 1);
			   $opt_apt_update = 1;
		       },
		       "apt-upgrade" => sub {
			   if ($opt_no_apt_upgrade) {
			       die "--apt-upgrade cannot be used together with --no-apt-upgrade";
			   }
			   $self->set_conf('APT_UPGRADE', 1);
			   $opt_apt_upgrade = 1;
		       },
		       "apt-distupgrade" => sub {
			   if ($opt_no_apt_distupgrade) {
			       die "--apt-distupgrade cannot be used together with --no-apt-distupgrade";
			   }
			   $self->set_conf('APT_DISTUPGRADE', 1);
			   $opt_apt_distupgrade = 1;
		       },
		       "no-apt-clean" => sub {
			   if ($opt_apt_clean) {
			       die "--no-apt-clean cannot be used together with --apt-clean";
			   }
			   $self->set_conf('APT_CLEAN', 0);
			   $opt_no_apt_clean = 1;
		       },
		       "no-apt-update" => sub {
			   if ($opt_apt_update) {
			       die "--no-apt-update cannot be used together with --apt-update";
			   }
			   $self->set_conf('APT_UPDATE', 0);
			   $opt_no_apt_update = 1;
		       },
		       "no-apt-upgrade" => sub {
			   if ($opt_apt_upgrade) {
			       die "--no-apt-upgrade cannot be used together with --apt-upgrade";
			   }
			   $self->set_conf('APT_UPGRADE', 0);
			   $opt_no_apt_upgrade = 1;
		       },
		       "no-apt-distupgrade" => sub {
			   if ($opt_apt_distupgrade) {
			       die "--no-apt-distupgrade cannot be used together with --apt-distupgrade";
			   }
			   $self->set_conf('APT_DISTUPGRADE', 0);
			   $opt_no_apt_distupgrade = 1;
		       },
		       "d|dist=s" => sub {
			   $self->set_conf('DISTRIBUTION', $_[1]);
			   $self->set_conf('DISTRIBUTION', "oldstable")
			       if $self->get_conf('DISTRIBUTION') eq "o";
			   $self->set_conf('DISTRIBUTION', "stable")
			       if $self->get_conf('DISTRIBUTION') eq "s";
			   $self->set_conf('DISTRIBUTION', "testing")
			       if $self->get_conf('DISTRIBUTION') eq "t";
			   $self->set_conf('DISTRIBUTION', "unstable")
			       if $self->get_conf('DISTRIBUTION') eq "u";
			   $self->set_conf('DISTRIBUTION', "experimental")
			       if $self->get_conf('DISTRIBUTION') eq "e";
			   $self->set_conf('OVERRIDE_DISTRIBUTION', 1);
		       },
		       "force-orig-source" => sub {
			   $self->set_conf('FORCE_ORIG_SOURCE', 1);
		       },
		       "m|maintainer=s" => sub {
			   $self->set_conf('MAINTAINER_NAME', $_[1]);
		       },
		       "mailfrom=s" => sub {
			   $self->set_conf('MAILFROM', $_[1]);
		       },
		       "sbuild-mode=s" => sub {
			   $self->set_conf('SBUILD_MODE', $_[1]);
		       },
		       "k|keyid=s" => sub {
			   $self->set_conf('KEY_ID', $_[1]);
		       },
		       "e|uploader=s" => sub {
			   $self->set_conf('UPLOADER_NAME', $_[1]);
		       },
		       "debbuildopts=s" => sub {
			   push(@{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "debbuildopt=s" => sub {
			   push(@{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')},
				$_[1]);
		       },
		       "dpkg-file-suffix=s" => sub {
			   $self->set_conf('DPKG_FILE_SUFFIX', $_[1]);
		       },
		       "j|jobs=i" => sub {
			   push(@{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')},
				'-j'.$_[1])
		       },
		       "dpkg-source-opts=s" => sub {
			   push(@{$self->get_conf('DPKG_SOURCE_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "dpkg-source-opt=s" => sub {
			   push(@{$self->get_conf('DPKG_SOURCE_OPTIONS')},
				$_[1]);
		       },
		       "mail-log-to=s" => sub {
			   $self->set_conf('MAILTO', $_[1]);
			   $self->set_conf('MAILTO_FORCED_BY_CLI', "yes");
		       },
		       "n|nolog" => sub {
			   $self->set_conf('NOLOG', 1);
		       },
		       "p|purge=s" => sub {
			   if (defined $opt_purge_build) {
			       die "cannot specify --purge together with --purge-build";
			   }
			   if (defined $opt_purge_deps) {
			       die "cannot specify --purge together with --purge-deps";
			   }
			   if (defined $opt_purge_session) {
			       die "cannot specify --purge together with --purge-session";
			   }
			   $self->set_conf('PURGE_BUILD_DEPS', $_[1]);
			   $self->set_conf('PURGE_BUILD_DIRECTORY', $_[1]);
			   $self->set_conf('PURGE_SESSION', $_[1]);
			   $opt_purge = 1;
		       },
		       "purge-build=s" => sub {
			   if (defined $opt_purge) {
			       die "cannot specify --purge-build together with --purge";
			   }
			   $self->set_conf('PURGE_BUILD_DIRECTORY', $_[1]);
			   $opt_purge_build = 1;
		       },
		       "purge-deps=s" => sub {
			   if (defined $opt_purge) {
			       die "cannot specify --purge-deps together with --purge";
			   }
			   $self->set_conf('PURGE_BUILD_DEPS', $_[1]);
			   $opt_purge_deps = 1;
		       },
		       "purge-session=s" => sub {
			   if (defined $opt_purge) {
			       die "cannot specify --purge-session together with --purge";
			   }
			   $self->set_conf('PURGE_SESSION', $_[1]);
			   $opt_purge_session = 1;
		       },
		       "s|source" => sub {
			   if ($opt_no_source) {
			       die "--source cannot be used together with --no-source";
			   }
			   $self->set_conf('BUILD_SOURCE', 1);
			   $opt_source = 1;
		       },
		       "no-source" => sub {
			   if ($opt_source) {
			       die "--no-source cannot be used together with --source";
			   }
			   $self->set_conf('BUILD_SOURCE', 0);
			   $opt_no_source = 1;
		       },
		       "archive=s" => sub {
			   $self->set_conf('ARCHIVE', $_[1]);
		       },
		       "stats-dir=s" => sub {
			   $self->set_conf('STATS_DIR', $_[1]);
		       },
		       "setup-hook=s" => sub {
			push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"chroot-setup-commands"}},
			$_[1]);
			   $self->set_conf('CHROOT_SETUP_SCRIPT', $_[1]);
		       },
		       "use-snapshot" => sub {
			   my $newldpath = '/usr/lib/gcc-snapshot/lib';
			   my $ldpath = $self->get_conf('LD_LIBRARY_PATH');
			   if (defined($ldpath) && $ldpath ne '') {
			       $newldpath .= ':' . $ldpath;
			   }

			   $self->set_conf('GCC_SNAPSHOT', 1);
			   $self->set_conf('LD_LIBRARY_PATH', $newldpath);
			   $self->set_conf('PATH',
					   '/usr/lib/gcc-snapshot/bin' .
					   $self->get_conf('PATH') ne '' ? ':' . $self->get_conf('PATH') : '');
		       },
		       "build-dep-resolver=s" => sub {
			   $self->set_conf('BUILD_DEP_RESOLVER', $_[1]);
		       },
		       "aspcud-criteria=s" => sub {
			   $self->set_conf('ASPCUD_CRITERIA', $_[1]);
		       },
		       "resolve-alternatives" => sub {
			   if ($opt_no_resolve_alternatives) {
			       die "--resolve-alternatives cannot be used together with --no-resolve-alternatives";
			   }
			   $self->set_conf('RESOLVE_ALTERNATIVES', 1);
			   $opt_resolve_alternatives = 1;
		       },
		       "no-resolve-alternatives" => sub {
			   if ($opt_resolve_alternatives) {
			       die "--no-resolve-alternatives cannot be used together with --resolve-alternatives";
			   }
			   $self->set_conf('RESOLVE_ALTERNATIVES', 0);
			   $opt_no_resolve_alternatives = 1;
		       },
			"clean-source" => sub {
			    if ($opt_no_clean_source) {
				die "--clean-source cannot be used together with --no-clean-source";
			    }
			    $self->set_conf('CLEAN_SOURCE', 1);
			    $opt_clean_source = 1;
		       },
			"no-clean-source" => sub {
			    if ($opt_clean_source) {
				die "--no-clean-source cannot be used together with --clean-source";
			    }
			    $self->set_conf('CLEAN_SOURCE', 0);
			    $opt_no_clean_source = 1;
		       },
			"run-lintian" => sub {
			    if ($opt_no_run_lintian) {
				die "--run-lintian cannot be used together with --no-run-lintian";
			    }
			    $self->set_conf('RUN_LINTIAN', 1);
			    $opt_run_lintian = 1;
		       },
		       "no-run-lintian" => sub {
			    if ($opt_run_lintian) {
				die "--no-run-lintian cannot be used together with --run-lintian";
			    }
			    $self->set_conf('RUN_LINTIAN', 0);
			    $opt_no_run_lintian = 1;
		       },
		       "lintian-opts=s" => sub {
			   push(@{$self->get_conf('LINTIAN_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "lintian-opt=s" => sub {
			   push(@{$self->get_conf('LINTIAN_OPTIONS')},
				$_[1]);
		       },
		       "run-piuparts" => sub {
			    if ($opt_no_run_piuparts) {
				die "--run-piuparts cannot be used together with --no-run-piuparts";
			    }
			    $self->set_conf('RUN_PIUPARTS', 1);
			    $opt_run_piuparts = 1;
		       },
		       "no-run-piuparts" => sub {
			    if ($opt_run_piuparts) {
				die "--no-run-piuparts cannot be used together with --run-piuparts";
			    }
			    $self->set_conf('RUN_PIUPARTS', 0);
			    $opt_no_run_piuparts = 1;
		       },
		       "piuparts-opts=s" => sub {
			   push(@{$self->get_conf('PIUPARTS_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "piuparts-opt=s" => sub {
			   push(@{$self->get_conf('PIUPARTS_OPTIONS')},
				$_[1]);
		       },
		       "piuparts-root-args=s" => sub {
			   push(@{$self->get_conf('PIUPARTS_ROOT_ARGS')},
				split(/\s+/, $_[1]));
		       },
		       "piuparts-root-arg=s" => sub {
			   push(@{$self->get_conf('PIUPARTS_ROOT_ARGS')},
				$_[1]);
		       },
		       "run-autopkgtest" => sub {
			    if ($opt_no_run_autopkgtest) {
				die "--run-autopkgtest cannot be used together with --no-run-autopkgtest";
			    }
			    $self->set_conf('RUN_AUTOPKGTEST', 1);
			    $opt_run_autopkgtest = 1;
		       },
		       "no-run-autopkgtest" => sub {
			    if ($opt_run_autopkgtest) {
				die "--no-run-autopkgtest cannot be used together with --run-autopkgtest";
			    }
			    $self->set_conf('RUN_AUTOPKGTEST', 0);
			    $opt_no_run_autopkgtest = 1;
		       },
		       "autopkgtest-opts=s" => sub {
			   push(@{$self->get_conf('AUTOPKGTEST_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "autopkgtest-opt=s" => sub {
			   push(@{$self->get_conf('AUTOPKGTEST_OPTIONS')},
				$_[1]);
		       },
		       "autopkgtest-root-args=s" => sub {
			   # special handling of the case when the string
			   # argument is the empty string. In that case, the
			   # empty string is appended. The split function
			   # would just return an empty list when splitting
			   # the empty string
			   if ($_[1] eq '') {
			       push(@{$self->get_conf('AUTOPKGTEST_ROOT_ARGS')},
				   '');
			   } else {
			       push(@{$self->get_conf('AUTOPKGTEST_ROOT_ARGS')},
				   split(/\s+/, $_[1]));
			   }
		       },
		       "autopkgtest-root-arg=s" => sub {
			   push(@{$self->get_conf('AUTOPKGTEST_ROOT_ARGS')},
				$_[1]);
		       },
			"pre-build-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"pre-build-commands"}},
				$_[1]);
		       },
			"chroot-setup-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"chroot-setup-commands"}},
				$_[1]);
		       },
			"chroot-update-failed-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"chroot-update-failed-commands"}},
				$_[1]);
		       },
			"build-deps-failed-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"build-deps-failed-commands"}},
				$_[1]);
		       },
			"build-failed-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"build-failed-commands"}},
				$_[1]);
		       },
			"anything-failed-commands=s" => sub {

			   # --anything-failed-commands simply triggers all the
			   # --xxx-failed-commands I know about

			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"chroot-update-failed-commands"}},
				$_[1]);
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"build-deps-failed-commands"}},
				$_[1]);
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"build-failed-commands"}},
				$_[1]);
		       },
			"starting-build-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"starting-build-commands"}},
				$_[1]);
		       },
			"finished-build-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"finished-build-commands"}},
				$_[1]);
		       },
			"chroot-cleanup-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"chroot-cleanup-commands"}},
				$_[1]);
		       },
			"post-build-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"post-build-commands"}},
				$_[1]);
		       },
			"post-build-failed-commands=s" => sub {
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"post-build-failed-commands"}},
				$_[1]);
		       },
			"log-external-command-output" => sub {
			    $self->set_conf('LOG_EXTERNAL_COMMAND_OUTPUT', 1);
		       },
			"log-external-command-error" => sub {
			    $self->set_conf('LOG_EXTERNAL_COMMAND_ERROR', 1);
		       },
			"extra-package=s" => sub {
			   push(@{$self->get_conf('EXTRA_PACKAGES')}, $_[1]);
		       },
			"extra-repository=s" => sub {
			   push(@{$self->get_conf('EXTRA_REPOSITORIES')}, $_[1]);
		       },
			"extra-repository-key=s" => sub {
			   push(@{$self->get_conf('EXTRA_REPOSITORY_KEYS')}, $_[1]);
		       },
			"build-path=s" => sub {
			   $self->set_conf('BUILD_PATH', $_[1]);
			},
			"dsc-dir=s" => sub {
			   $self->set_conf('DSC_DIR', $_[1]);
			},
			"source-only-changes" => sub {
			   $self->set_conf('SOURCE_ONLY_CHANGES', 1);
			},
			"no-source-only-changes" => sub {
			   $self->set_conf('SOURCE_ONLY_CHANGES', 0);
			},
			"purge-extra-packages" => sub {
			    $self->set_conf('PURGE_EXTRA_PACKAGES', 1);
			},
			"bd-uninstallable-explainer=s" => sub {
			   $self->set_conf('BD_UNINSTALLABLE_EXPLAINER', $_[1]);
			}
	);
}

=pod
This function allows to extrapolate from the parsed and set options some
expected behaviours.
=cut
sub extrapolate_options {
    my $self = shift;

    # This allows to pass -sa to all commands instead of passing it just to dpkg-buildpackage
    push (@{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')}, "-sa") if ($self->get_conf('BUILD_SOURCE') && $self->get_conf('FORCE_ORIG_SOURCE'));
}

1;
