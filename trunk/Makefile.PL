#!/usr/bin/perl
#
#   Perl Makefile for Danga-Socket
#   $Id$
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'Danga::Socket',
    VERSION_FROM            => 'Socket.pm', # finds $VERSION
    AUTHOR                  => 'Michael Granger <ged@danga.com>',
    ABSTRACT                => 'Async socket class',
    PREREQ_PM               => {
        'Socket'        => 0,
        'IO::Poll'      => 0,
        fields          => 0,
    },
    dist                    => {
        CI                      => "cvs commit",
        RCS_LABEL               => 'cvs tag RELEASE_$(VERSION_SYM)',
        SUFFIX                  => ".bz2",
        DIST_DEFAULT            => 'all tardist',
        COMPRESS                => "bzip2",
    },

);

