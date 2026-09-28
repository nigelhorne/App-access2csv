use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
	NAME         => 'App::Access2CSV',
	VERSION_FROM => 'lib/App/Access2CSV.pm',
	ABSTRACT_FROM => 'lib/App/Access2CSV.pm',
	AUTHOR       => 'Nigel Horne <njh@nigelhorne.com>',

	EXE_FILES => [
		'bin/access2csv',
	],

	PREREQ_PM => {
		'autodie'      => 0,
		'Carp'         => 0,
		'Encode'       => 0,
		'File::Path'   => 0,
		'File::Spec'   => 0,
		'File::Temp'   => 0,
		'File::Which'  => 0,
		'Getopt::Long' => 0,
		'IPC::Run3'    => 0,
		'IPC::System::Simple' => 0,	# needed by autodie qw(:all)
		'Log::Abstraction' => 0,
		'Params::Get'  => 0,
		'Params::Validate::Strict' => 0.40,
		'parent'       => 0,
		'Pod::Usage'   => 0,
		'Readonly'     => 0,
		'Return::Set'  => 0,
		'Sub::Private' => 0.05,	# first version with enforce mode
		'Sub::Protected' => 0,
	},

	TEST_REQUIRES => {
		'Capture::Tiny' => 0,
		'Errno'        => 0,
		'POSIX'        => 0,
		'Test::Memory::Cycle' => 0,
		'Test::Mockingbird' => 0.13,	# mock_scoped multi-method form
		'Test::Most'   => 0,
		'Test::Returns' => 0,
		'Test::Without::Module' => 0,
	},

	LICENSE => 'gpl_2',
);
