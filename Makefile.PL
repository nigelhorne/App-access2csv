use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'App::Access2csv',
    VERSION_FROM => 'lib/App/Access2CSV.pm',

    EXE_FILES => [
        'bin/access2csv',
    ],

    PREREQ_PM => {
        'autodie'      => 0,
        'Encode'       => 0,
        'File::Path'   => 0,
        'File::Spec'   => 0,
	'File::Which' => 0,
        'Getopt::Long' => 0,
        'IPC::Run3'    => 0,
        'Pod::Usage'   => 0,
    },

    LICENSE => 'perl',
);
