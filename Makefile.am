# sbuild Makefile template
#
#
# Copyright © 2004-2007  Roger Leigh <rleigh@debian.org>
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

SUBDIRS = bin tools configs etc lib man db test

dist-hook:
# Remove junk from the generated tarball.
	$(FIND) $(distdir) -name '.*' -print | $(XARGS) xargs $(RM) -rf
	$(FIND) $(distdir) -name '#*' -print | $(XARGS) $(RM) -rf
	$(FIND) $(distdir) -name '*~' -print | $(XARGS) $(RM) -rf

EXTRA_DIST =				\
	bootstrap			\
	lisp				\
	scripts/git-tag-release		\
	ChangeLog-buildd		\
	HACKING				\
	Makefile-buildd			\
	NEWS-buildd			\
	README.buildd-admin		\
	README.chroot-building

ps:
	$(MAKE) -C doc sbuild.ps

pdf:
	$(MAKE) -C doc sbuild.pdf

.PHONY: ps pdf
