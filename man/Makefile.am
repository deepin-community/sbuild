# sbuild Makefile template
#
#
# Copyright © 2004-2008  Roger Leigh <rleigh@debian.org>
#
# sbuild is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# sbuild is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#####################################################################

include $(top_srcdir)/scripts/global.mk

man_MANS =				\
	buildd.1			\
	buildd.conf.5			\
	buildd-mail.1			\
	buildd-uploader.1		\
	buildd-vlog.1			\
	buildd-watcher.1		\
	sbuild.1			\
	sbuild.conf.5			\
	sbuild-abort.1			\
	sbuild-adduser.8		\
	sbuild-apt.1			\
	sbuild-checkpackages.1		\
	sbuild-createchroot.8		\
	sbuild-debian-developer-setup.1 \
	sbuild-destroychroot.8		\
	sbuild-hold.1			\
	sbuild-qemu.1			\
	sbuild-qemu-boot.1		\
	sbuild-qemu-create.1		\
	sbuild-qemu-update.1		\
	sbuild-setup.7			\
	sbuild-shell.1			\
	sbuild-update.1

sbuild.conf.man: $(abs_top_srcdir)/tools/sbuild-dumpconfig $(abs_top_srcdir)/lib/Sbuild/Conf.pm $(abs_top_srcdir)/lib/Sbuild/ConfBase.pm
	PERL5LIB=$(abs_top_srcdir)/lib:$(abs_top_builddir)/lib \
	  $< sbuild man > $@

buildd.conf.man: $(abs_top_srcdir)/tools/sbuild-dumpconfig $(abs_top_srcdir)/lib/Buildd/Conf.pm
	PERL5LIB=$(abs_top_srcdir)/lib:$(abs_top_builddir)/lib \
	  $< buildd man > $@

sbuild.conf.5: sbuild.conf.5.in defs.man sbuild.conf.man
	soelim -r $< > $@
# \$ (used in the example for $environment_filter) needs to be escaped as \e$
	sed -i 's/\\\$$/\\e$$/g' $@

buildd.conf.5: buildd.conf.5.in defs.man buildd.conf.man
	soelim -r $< > $@

%.1: %.1.in defs.man
	soelim -r $< > $@

%.5: %.5.in defs.man
	soelim -r $< > $@

%.7: %.7.in defs.man
	soelim -r $< > $@

%.8: %.8.in defs.man
	soelim -r $< > $@

CLEANFILES = 				\
	sbuild.conf.man			\
	buildd.conf.man

EXTRA_DIST =				\
	defs.man.in			\
	$(addsuffix .in, $(man_MANS))

install-data-hook:
	ln -sf sbuild-hold.1 $(DESTDIR)$(man1dir)/sbuild-unhold.1
	ln -sf sbuild-update.1 $(DESTDIR)$(man1dir)/sbuild-upgrade.1
	ln -sf sbuild-update.1 $(DESTDIR)$(man1dir)/sbuild-distupgrade.1
	ln -sf sbuild-update.1 $(DESTDIR)$(man1dir)/sbuild-clean.1
	ln -sf sbuild-abort.1 $(DESTDIR)$(man1dir)/buildd-abort.1
	ln -sf sbuild-update.1 $(DESTDIR)$(man1dir)/buildd-update-chroots.1
	ln -sf sbuild-createchroot.8 $(DESTDIR)$(man8dir)/buildd-make-chroot.8

uninstall-hook:
	$(RM) $(DESTDIR)$(man1dir)/sbuild-unhold.1
	$(RM) $(DESTDIR)$(man1dir)/sbuild-upgrade.1
	$(RM) $(DESTDIR)$(man1dir)/sbuild-distupgrade.1
	$(RM) $(DESTDIR)$(man1dir)/sbuild-clean.1
	$(RM) $(DESTDIR)$(man1dir)/buildd-abort.1
	$(RM) $(DESTDIR)$(man1dir)/buildd-update-chroots.1
	$(RM) $(DESTDIR)$(man8dir)/buildd-make-chroot.8
