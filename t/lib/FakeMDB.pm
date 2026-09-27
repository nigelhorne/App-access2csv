package FakeMDB;

# Test helper: installs stand-in mdb-tables, mdb-export and mdb-count
# scripts in a temporary directory, so that the exporter can be tested
# without mdbtools or a real Access database.
#
# The "database" is a text file listing one table name per line; the
# fake mdb-tables prints it back.  A first line of "FAIL" makes
# mdb-tables fail.  mdb-export's behaviour depends on the table name:
#   Broken   - exits 1 with "corrupt table" on stderr
#   Killed   - kills itself with SIGTERM
#   Unicode  - UTF-8 text that cp1252 can represent ("Cafe" with e-acute, Euro)
#   Japanese - UTF-8 text that cp1252 cannot represent
#   Latin1   - bytes that are not valid UTF-8
#   anything else - a two-line CSV naming the table

use strict;
use warnings;
use autodie qw(:all);

use File::Spec;
use File::Temp qw(tempdir);

use Exporter qw(import);
our @EXPORT_OK = qw(install_fake_mdbtools make_database);

# Program bodies; each is run by the perl that runs the tests
my %SCRIPTS = (
	'mdb-tables' => <<'PERL',
my ($flag, $db) = @ARGV;
open my $fh, '<:raw', $db or do { print STDERR "cannot open $db\n"; exit 1 };
my @lines = <$fh>;
if(@lines && $lines[0] =~ /^FAIL/) { print STDERR "not an Access database\n"; exit 2 }
binmode STDOUT;
print @lines;
PERL
	'mdb-export' => <<'PERL',
my ($db, $table) = @ARGV;
binmode STDOUT;
if($table eq 'Broken') { print STDERR "corrupt table\n"; exit 1 }
if($table eq 'Killed') { kill 'TERM', $$; sleep 5; exit 0 }
my %body = (
	Unicode  => "Caf\xC3\xA9 \xE2\x82\xAC",
	Japanese => "\xE6\x97\xA5\xE6\x9C\xAC",
	Latin1   => "Caf\xE9",
);
my $value = exists $body{$table} ? $body{$table} : $table;
print "\"id\",\"name\"\n1,\"$value\"\n";
PERL
	'mdb-count' => <<'PERL',
print "1\n";
PERL
);

# install_fake_mdbtools(@programs)
# Writes the named fake programs (default: all three) to a new temporary
# directory and returns that directory, for prepending to $ENV{PATH}.
sub install_fake_mdbtools {
	my @programs = @_ ? @_ : sort keys %SCRIPTS;

	my $dir = tempdir(CLEANUP => 1);
	foreach my $program (@programs) {
		my $path = File::Spec->catfile($dir, $program);
		open my $fh, '>', $path;
		print {$fh} "#!$^X\nuse strict;\nuse warnings;\n$SCRIPTS{$program}";
		close $fh;
		chmod 0755, $path;
	}
	return $dir;
}

# make_database($dir, @tables)
# Creates a fake database listing @tables and returns its path.
sub make_database {
	my ($dir, @tables) = @_;

	my $path = File::Spec->catfile($dir, 'test.accdb');
	open my $fh, '>:raw', $path;
	print {$fh} map { "$_\n" } @tables;
	close $fh;
	return $path;
}

1;
