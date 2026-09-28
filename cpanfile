# Generated from Makefile.PL using makefilepl2cpanfile

requires 'Carp';
requires 'Encode';
requires 'File::Path';
requires 'File::Spec';
requires 'File::Temp';
requires 'File::Which';
requires 'Getopt::Long';
requires 'IPC::Run3';
requires 'IPC::System::Simple';   # needed by autodie qw(:all)
requires 'Log::Abstraction';
requires 'Params::Get';
requires 'Params::Validate::Strict', '0.40';
requires 'Pod::Usage';
requires 'Readonly';
requires 'Return::Set';
requires 'Scalar::Util';
requires 'Sub::Private', '0.05';   # first version with enforce mode
requires 'Sub::Protected';
requires 'autodie';
requires 'parent';

on 'test' => sub {
	requires 'Capture::Tiny';
	requires 'Errno';
	requires 'POSIX';
	requires 'Test::Memory::Cycle';
	requires 'Test::Mockingbird', '0.13';   # mock_scoped multi-method form
	requires 'Test::Most';
	requires 'Test::Returns';
	requires 'Test::Without::Module';
};

on 'develop' => sub {
	requires 'Devel::Cover';
	requires 'Perl::Critic';
	requires 'Test::Pod';
	requires 'Test::Pod::Coverage';
};
