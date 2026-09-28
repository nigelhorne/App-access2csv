package App::Access2CSV::Exporter;

use strict;
use warnings;
use autodie qw(:all);

# Sub::Private must be in enforce mode before it is loaded, so that
# private methods still work through $self->method dispatch
BEGIN { $Sub::Private::config{mode} = 'enforce' }

# Inherit i18n() and the protected _croak_i18n/_carp_i18n helpers
use parent 'App::Access2CSV::I18N';

use Encode qw(FB_CROAK);
use File::Path qw(make_path);
use File::Spec;
use File::Temp;
use File::Which qw(which);
use IPC::Run3 qw(run3);
use Params::Get qw(get_params);
use Params::Validate::Strict qw(validate_strict);
use Readonly;
use Return::Set qw(set_return);
use Sub::Private;
use Sub::Protected;

our $VERSION = '0.001.0';

# Stop Carp from reporting errors against the access-control wrappers
our @CARP_NOT = qw(Sub::Private Sub::Protected App::Access2CSV::I18N);

# Exit statuses returned by run()
Readonly::Scalar my $EXIT_OK      => 0;
Readonly::Scalar my $EXIT_FAILURE => 1;

# The mdbtools programs; mdb-count is only needed for --show-counts
Readonly::Scalar my $MDB_TABLES   => 'mdb-tables';
Readonly::Scalar my $MDB_EXPORT   => 'mdb-export';
Readonly::Scalar my $MDB_COUNT    => 'mdb-count';
Readonly::Array  my @REQUIRED_PROGRAMS => ($MDB_TABLES, $MDB_EXPORT);

# Output encodings accepted by --encoding
Readonly::Scalar my $ENC_UTF8     => 'utf8';
Readonly::Scalar my $ENC_UTF8_BOM => 'utf8-bom';
Readonly::Scalar my $ENC_CP1252   => 'cp1252';
Readonly::Array  my @ENCODINGS    => ($ENC_UTF8, $ENC_UTF8_BOM, $ENC_CP1252);

# Byte order mark written at the start of utf8-bom files (for Excel)
Readonly::Scalar my $UTF8_BOM     => "\xEF\xBB\xBF";

# Tables Access creates for itself: MSys*, USys* and ~temporary objects
Readonly::Scalar my $SYSTEM_TABLE_RE => qr/\A(?:MSys|USys|~)/i;

# Characters that are illegal in a file name on at least one common OS
Readonly::Scalar my $UNSAFE_CHARS_RE => qr/[<>:"\/\\|?*\x00-\x1F\x7F]/;

# Device names Windows reserves whatever the extension (CON.csv is illegal)
Readonly::Scalar my $RESERVED_NAME_RE => qr/\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i;

# Name used when sanitising leaves nothing, and the extension we write
Readonly::Scalar my $UNNAMED      => 'unnamed';
Readonly::Scalar my $CSV_SUFFIX   => '.csv';

# Ends option parsing in mdbtools, so a table or database name that
# starts with "-" is never taken for an option (glib parses options
# anywhere on the command line, not only before the file name)
Readonly::Scalar my $END_OF_OPTIONS => '--';

# Temporary files are hidden and live next to the target for atomic rename
Readonly::Scalar my $TEMP_TEMPLATE => '.access2csv-XXXXXX';

# Dry-run table layout
Readonly::Scalar my $TABLE_COLUMN_WIDTH => 40;
Readonly::Scalar my $ROWS_COLUMN_WIDTH  => 10;
Readonly::Scalar my $RULE_WIDTH         => 70;

# Mode bits for new files before the umask is applied
Readonly::Scalar my $FILE_MODE    => oct('666');

# Default settings; the flat scalar layout is compatible with Object::Configure
Readonly::Hash my %DEFAULTS => (
	output_dir  => File::Spec->curdir(),
	overwrite   => 0,
	verbose     => 0,
	dry_run     => 0,
	show_counts => 0,
	progress    => 1,
	encoding    => $ENC_UTF8,
);

# Constructor argument schema, shared by new() and the POD
Readonly::Hash my %NEW_SCHEMA => (
	output_dir  => { type => 'string', min => 1, optional => 1 },
	tables      => { type => 'arrayref', element_type => 'string', optional => 1 },
	overwrite   => { type => 'boolean', optional => 1 },
	verbose     => { type => 'boolean', optional => 1 },
	dry_run     => { type => 'boolean', optional => 1 },
	show_counts => { type => 'boolean', optional => 1 },
	progress    => { type => 'boolean', optional => 1 },
	encoding    => { type => 'string', memberof => [@ENCODINGS], optional => 1 },
	logger      => { type => 'object', can => ['debug', 'info', 'warn'], optional => 1 },
	language    => { type => 'string', optional => 1 },
);

=encoding utf8

=head1 NAME

App::Access2CSV::Exporter - Export the tables of a Microsoft Access database to CSV files

=head1 VERSION

Version 0.001.0

=head1 SYNOPSIS

	use App::Access2CSV::Exporter;

	# 1. The simplest case: every table, into the current folder
	my $exporter = App::Access2CSV::Exporter->new();
	my $status = $exporter->run('shop.accdb');	# 0 = all OK, 1 = some failed

	# 2. Some tables, into a folder, for Excel, replacing old files
	my $exporter = App::Access2CSV::Exporter->new(
		output_dir => 'exports',
		tables     => ['Customers', 'Orders'],
		encoding   => 'utf8-bom',
		overwrite  => 1,
	);
	$exporter->run('shop.accdb');

	# 3. Only look: print the table list and row counts, write nothing
	App::Access2CSV::Exporter->new(dry_run => 1, show_counts => 1)->run('shop.accdb');

	# 4. Inside a larger program: no progress lines, a log, and full
	#    error handling
	use Log::Abstraction;

	my $exporter = App::Access2CSV::Exporter->new({
		output_dir => '/srv/exports',
		progress   => 0,
		logger     => Log::Abstraction->new(logger => '/var/log/export.log'),
	});
	my $status = eval { $exporter->run('/data/shop.accdb') };
	if(!defined $status) {
		die "Nothing was exported: $@";	# for example, the file is missing
	} elsif($status == 1) {
		warn "Some tables were not exported; see the log\n";
	}

=head1 DESCRIPTION

This module does the real work of the C<access2csv> program.  It writes
one CSV file for each table of a Microsoft Access database.

It runs three programs from the B<mdbtools> package: C<mdb-tables> (to
list the tables), C<mdb-export> (to get each table as CSV) and, only when
row counts are wanted, C<mdb-count>.  They must be in your C<PATH>.

Access's own internal tables (names starting with C<MSys>, C<USys> or
C<~>) are skipped.

Each file is first written to a hidden temporary file in the output
folder, and renamed to its real name only when it is complete.  So a
failed export never leaves a half-written CSV file, and an old file is
only replaced by a complete new one.  New files get the usual
permissions (0666 minus your umask).

An exporter can be used for more than one C<run>.  Each C<run> starts
again with the same file names, so running twice gives the same files.

Table names and the database path are handed to mdbtools as separate
arguments, never through a shell, and after a C<--> marker.  So names
containing shell characters (C<; | E<gt> $( )>), spaces or newlines, or
starting with C<->, are always treated as names, never as commands or
options.  A table name can never place a file outside the output
folder: C</> and C<\> are replaced, and names cannot start with a dot.

An existing entry at the target name - including a symbolic link, even a
broken one - counts as "already exists".  With C<overwrite>, the link
itself is replaced; the file it pointed to is never written.

The rules for file names are described in
L<App::Access2CSV/How the CSV files are named>.

=head1 ENCODING

=over 4

=item * B<CSV data.>  mdbtools gives UTF-8.  With C<encoding> set to
C<utf8> or C<utf8-bom> the bytes are copied exactly, so every character,
including emoji and non-Latin scripts, is kept.  C<utf8-bom> also writes
the three-byte UTF-8 "byte order mark" first, which Microsoft Excel
needs.  With C<cp1252>, each line is converted to Windows-1252; if a line
has a character that Windows-1252 does not have (for example Greek,
Chinese or an emoji), that table fails and nothing is written for it.

=item * B<Database path and output_dir.>  These are passed to the operating
system unchanged.  Give them as byte strings (the form you get from
C<@ARGV> or C<readdir>).  Non-ASCII names work on systems whose file names
are UTF-8, such as Linux and macOS.

=item * B<Table names> (in C<tables>).  They are compared with the names
that C<mdb-tables> prints, which are UTF-8 bytes.  So give UTF-8 byte
strings, not decoded Perl character strings.  If you have a decoded
string, use C<Encode::encode('UTF-8', $name)> first.  The CSV file name is
made from the same bytes, so non-ASCII names and emoji are kept.

=item * B<Messages.>  All messages are plain ASCII English.

=back

=head1 COMMON PITFALLS

=over 4

=item * B<undef means "use the default", not "false".>  In C<new>,
C<< overwrite => undef >> is the same as not giving C<overwrite> at all.
To switch something off, give C<0>.

=item * B<An empty table list exports nothing.>  C<< tables => undef >>
(or no C<tables>) means "all tables".  C<< tables => [] >> means "no
tables": nothing is exported, and C<run> returns 0.

=item * B<Table names are case-sensitive.>  C<'orders'> does not match the
table C<Orders>.  Names that do not match any table give a warning.

=item * B<A failing logger does not stop the export.>  If the logger dies
(for example, its disk is full), C<run> warns once with "Cannot write to
the log", stops logging for this exporter, and carries on exporting.

=item * B<run can croak.>  C<run> returns 1 when some tables fail, but it
croaks (throws an exception) when nothing can be exported at all: the
database is missing or unreadable, mdbtools is not installed, or the
output folder cannot be created.  Wrap C<run> in C<eval> if your program
must keep going.

=item * B<run may change the show_counts setting.>  If C<show_counts> is
on but C<mdb-count> cannot be found, C<run> warns and switches
C<show_counts> off for this exporter.

=item * B<Settings are copied, not shared.>  C<new> makes its own copy of
the C<tables> list; changing your array later has no effect.  Settings are
not merged in depth: a new C<tables> list replaces the default completely.

=item * B<Warnings go through carp.>  Failed tables and unknown table names
are reported with C<carp>, so they appear on standard error (or in your
C<$SIG{__WARN__}> handler) even when a logger is given.

=item * B<Load the module with use, not require.>  Protection of the
private methods is set up at compile time.  After a run-time
C<require> Perl prints "Too late to run CHECK block" and the protection is
missing.

=back

=head1 METHODS

=head2 new

=head3 Purpose

Make a new exporter with your settings.  Nothing is checked on disk yet.

=head3 Arguments

Named arguments, either as a list or as one hash reference.  All of them
are optional.  An argument whose value is C<undef> is ignored, so its
default is used.

=over 4

=item C<output_dir> - the folder for the CSV files.  Default: the current folder.

=item C<tables> - an array reference of table names to export.  Default:
all tables.  An empty array means no tables.

=item C<overwrite> - true to replace CSV files that already exist.  Default: false.

=item C<verbose> - true to log extra detail.  Default: false.

=item C<dry_run> - true to only print what would be written.  Default: false.

=item C<show_counts> - true to report row counts (needs C<mdb-count>).  Default: false.

=item C<progress> - true to print C<[n/total] table> lines to standard
error.  Default: true.

=item C<encoding> - C<utf8>, C<utf8-bom> or C<cp1252>.  Default: C<utf8>.

=item C<logger> - an object with C<debug>, C<info> and C<warn> methods,
such as a L<Log::Abstraction> object.  Default: no logging.

=item C<language> - a language code such as C<en> for messages.  Default:
taken from the locale (see L<App::Access2CSV::I18N>).

=back

=head3 Returns

A new C<App::Access2CSV::Exporter> object.

=head3 Side Effects

None.  Your C<$@>, C<$!> and C<$_> are left as they were.

=head3 Usage

	my $exporter = App::Access2CSV::Exporter->new({ dry_run => 1 });

=head3 EXAMPLE

	# Export two tables as Windows-1252, replacing older files, with a log
	my $exporter = App::Access2CSV::Exporter->new(
		output_dir => 'out',
		tables     => ['Customers', 'Orders'],
		encoding   => 'cp1252',
		overwrite  => 1,
		logger     => Log::Abstraction->new(logger => 'export.log'),
	);

=head3 API SPECIFICATION

=head4 Input

	{
		output_dir  => { type => 'string', min => 1, optional => 1 },
		tables      => { type => 'arrayref', element_type => 'string', optional => 1 },
		overwrite   => { type => 'boolean', optional => 1 },
		verbose     => { type => 'boolean', optional => 1 },
		dry_run     => { type => 'boolean', optional => 1 },
		show_counts => { type => 'boolean', optional => 1 },
		progress    => { type => 'boolean', optional => 1 },
		encoding    => { type => 'string', memberof => ['utf8', 'utf8-bom', 'cp1252'], optional => 1 },
		logger      => { type => 'object', can => ['debug', 'info', 'warn'], optional => 1 },
		language    => { type => 'string', optional => 1 },
	}

=head4 Output

	{
		type => 'object',
		isa  => 'App::Access2CSV::Exporter',
	}

=head3 MESSAGES

These messages come from L<Params::Validate::Strict>.  They are fatal and
are not translated.

	+--------------------------------------+------------------------------+-----------------------------+
	| Message                              | Meaning                      | What to do                  |
	+--------------------------------------+------------------------------+-----------------------------+
	| Unknown parameter 'X'                | X is not a known setting     | Remove X, or fix its        |
	|                                      |                              | spelling                    |
	| Parameter 'encoding' (X) must be one | This encoding is not         | Use utf8, utf8-bom or       |
	|  of utf8, utf8-bom, cp1252           | supported                    | cp1252                      |
	| Parameter 'logger' must be an object | logger is not an object      | Give a logger object        |
	| Parameter 'tables' must be ...       | tables is not an array       | Give an array reference     |
	|                                      | reference                    |                             |
	+--------------------------------------+------------------------------+-----------------------------+

=cut

sub new {
	my $class = shift;

	# Validation uses eval internally; the caller's $@ must survive
	local $@;

	# Drop undefined values so that "not given" means "use the default"
	my $args = get_params(undef, \@_) || {};
	my %given = map { $_ => $args->{$_} } grep { defined $args->{$_} } keys %{$args};

	my $params = validate_strict(schema => { %NEW_SCHEMA }, input => \%given);

	# Copy the table list so later changes by the caller cannot affect us
	$params->{tables} = [ @{ $params->{tables} } ] if $params->{tables};

	my $self = bless { %DEFAULTS, %{$params}, used_names => {}, programs => {} }, $class;
	return set_return($self, { type => 'object' });
}

=head2 run

=head3 Purpose

Export the selected tables of one database to CSV files.  In dry-run mode,
only print what would be exported.

=head3 Arguments

=over 4

=item C<database> (string, required) - the path of the C<.mdb> or C<.accdb> file

=back

You can give it on its own, C<< $exporter->run('shop.accdb') >>, or as a
hash reference, C<< $exporter->run({ database => 'shop.accdb' }) >>.

=head3 Returns

C<0> if every selected table was exported, or in dry-run mode.
C<1> if at least one table was not exported (the others were).

=head3 Side Effects

=over 4

=item * Creates the output folder if needed (not in dry-run mode).

=item * Writes one CSV file per table (not in dry-run mode).

=item * Prints progress lines to standard error, if C<progress> is on.

=item * Prints the dry-run list to standard output, in dry-run mode.

=item * Sends messages to the logger, if there is one.

=item * Warns (with C<carp>) about each table that failed, about unknown
names in C<tables>, and about a missing C<mdb-count>.

=item * Croaks, before writing anything, if the database cannot be read, a
needed mdbtools program is missing, C<mdb-tables> fails, or the output
folder cannot be created.

=item * Switches C<show_counts> off for this exporter if C<mdb-count> is
missing.

=item * Leaves your C<$@>, C<$!>, C<$?>, C<$_> and any pending C<alarm>
as they were (except that a croak sets C<$@> in your C<eval>, as usual).

=back

=head3 Usage

	exit $exporter->run('shop.accdb');

=head3 EXAMPLE

	my $exporter = App::Access2CSV::Exporter->new(output_dir => 'out');

	# eval catches the fatal errors; the return value covers the rest
	my $status = eval { $exporter->run('shop.accdb') };
	if(!defined $status) {
		print STDERR "Nothing was exported: $@";
	} elsif($status) {
		print STDERR "Some tables failed; see the warnings above\n";
	} else {
		print "Done\n";
	}

=head3 API SPECIFICATION

=head4 Input

	{
		database => {
			type     => 'string',
			min      => 1,
			optional => 0,
		},
	}

=head4 Output

	{
		type => 'integer',
		min  => 0,
		max  => 1,
	}

=head3 MESSAGES

"fatal" means C<run> croaks and nothing is exported.  "per table" means
only that table fails; C<run> warns, logs, and carries on.

	+-----------------------------------------+------------------------------+-------------------------------+
	| Message                                 | Meaning                      | What to do                    |
	+-----------------------------------------+------------------------------+-------------------------------+
	| Cannot read database F: E (fatal)       | F does not exist, or cannot  | Check the path                |
	|                                         | be reached; E is the reason  |                               |
	|                                         | from the operating system    |                               |
	| Database F is not a regular file (fatal)| F is a folder or a device    | Give the database file        |
	| Database F is not readable (fatal)      | No permission to read F      | Fix the permissions           |
	|                                         | (never happens for root)     |                               |
	| Required program not found in PATH: P   | mdbtools is not installed,   | Install mdbtools, or fix PATH |
	|  (fatal)                                | or not in PATH               |                               |
	| mdb-tables failed with exit status N: E | mdbtools cannot read the     | Check that F is a real Access |
	|  (fatal)                                | file                         | database                      |
	| Cannot create output directory D: E     | The folder cannot be made;   | Check permissions and path    |
	|  (fatal)                                | E is the reason for D itself |                               |
	|                                         | (e.g. "Not a directory" when |                               |
	|                                         | a file is in the way)        |                               |
	| Tables not found in database: T         | Names in tables are not in   | Check spelling and case       |
	|  (warning)                              | the database                 |                               |
	| mdb-count not found in PATH; row counts | show_counts is on, but       | Install mdb-count, or turn    |
	|  are unavailable (warning)              | mdb-count is missing         | show_counts off               |
	| FAILED: T: E (warning, logged)          | Table T was not exported,    | See E, one of the messages    |
	|                                         | because of E                 | below                         |
	| Output file already exists: F (use      | F exists (a symbolic link,   | Set overwrite, or use another |
	|  --overwrite to replace it) (per table) | even a broken one, counts)   | output_dir                    |
	|                                         | and overwrite is off         |                               |
	| mdb-export failed with exit status N: E | mdbtools could not read this | Check the table in Access     |
	|  (per table)                            | table                        |                               |
	| P was killed by signal N (per table,    | The program was stopped from | Check memory and system       |
	|  or fatal for mdb-tables)               | outside                      | limits                        |
	| P could not be run: E (per table, or    | The program was found but    | Check its permissions and     |
	|  fatal for mdb-tables)                  | could not be started         | that it is a real program     |
	| Table T, line N: cannot be represented  | A character is not in        | Use utf8 or utf8-bom          |
	|  in cp1252 (per table)                  | Windows-1252                 |                               |
	| Table T, line N: output of mdb-export   | mdbtools gave bytes that are | Check the MDB_ICONV setting   |
	|  is not valid UTF-8 (per table)         | not UTF-8                    |                               |
	| Cannot write F: E (per table)           | The file could not be        | Check permissions and free    |
	|                                         | written or renamed into place| disk space                    |
	| Cannot write to the log: E (warning,    | The logger failed.  Exports  | Check the log's disk or       |
	|  once)                                  | go on; logging stops         | destination                   |
	+-----------------------------------------+------------------------------+-------------------------------+

=head3 PSEUDOCODE

	check the argument
	stop (croak) unless the database is a readable file
	find mdb-tables and mdb-export (croak if missing),
	     and mdb-count if row counts are wanted (warn if missing)
	forget the file names given out by any earlier run
	tables := the sorted user tables, filtered by "tables"
	          (warn about names that are not found)
	if dry run:
		print the table -> file list
		return 0
	create the output folder (croak if that fails)
	for each table:
		print "[n/total] table" if progress is on
		try to export the table
		if that failed: warn, log, and count the failure
	log the summary
	return 1 if any table failed, else 0

=cut

sub run {
	my $self = shift;

	# File tests, evals and child processes below would otherwise leave
	# their marks in the caller's $@ and $!
	local ($@, $!);

	# An undef database is a missing one, not a file called ""
	my $input = get_params('database', \@_);
	delete $input->{database} if ref($input) eq 'HASH' && !defined($input->{database});
	my $params = validate_strict(
		schema => { database => { type => 'string', min => 1 } },
		input  => $input,
	);
	my $database = $params->{database};

	# Fail fast, before any output, on problems that affect every table
	$self->_check_database($database)
		->_verify_dependencies()
		->_reset_names();

	my $tables = $self->_select_tables($self->_get_tables($database));

	# A dry run must not touch the file system, so it returns before mkdir
	my $status = $EXIT_OK;
	if($self->{dry_run}) {
		$self->_dry_run($database, $tables);
	} else {
		$self->_make_output_dir();
		my $failed = $self->_export_all($database, $tables);
		$status = $failed ? $EXIT_FAILURE : $EXIT_OK;
	}

	return set_return($status, { type => 'integer', min => $EXIT_OK, max => $EXIT_FAILURE });
}

# _check_database
# Purpose:        Make sure the database is a readable regular file.
# Entry Criteria: $database is a defined, non-empty path.
# Exit Status:    Returns $self for chaining; croaks otherwise.
# Side Effects:   stat()s the file; sets $!.
sub _check_database :Private {
	my ($self, $database) = @_;

	# The stat result is reused via "_" so the file is only examined once;
	# $! is captured straight away because later calls may overwrite it
	if(!-e $database) {
		$self->_croak_i18n('database_not_found', { params => [$database, "$!"] });
	}
	$self->_croak_i18n('database_not_file', { params => [$database] }) unless -f _;
	$self->_croak_i18n('database_unreadable', { params => [$database] }) unless -r _;

	return $self;
}

# _verify_dependencies
# Purpose:        Locate the mdbtools programs in PATH.
# Entry Criteria: None.
# Exit Status:    Returns $self; croaks if a required program is missing.
# Side Effects:   Sets $self->{programs}; may switch off show_counts (with a
#                 warning) when mdb-count is unavailable; logs at debug level.
sub _verify_dependencies :Private {
	my $self = shift;

	my %programs;
	foreach my $program (@REQUIRED_PROGRAMS) {
		$programs{$program} = $self->_find_program($program)
			or $self->_croak_i18n('program_missing', { params => [$program] });
	}

	# mdb-count is only needed for row counts, so its absence is not fatal
	if($self->{show_counts}) {
		$programs{$MDB_COUNT} = $self->_find_program($MDB_COUNT);
		if(!$programs{$MDB_COUNT}) {
			delete $programs{$MDB_COUNT};
			$self->{show_counts} = 0;
			$self->_warn('no_row_counter');
		}
	}

	$self->{programs} = \%programs;
	return $self;
}

# _find_program
# Purpose:        Look up one program in PATH and note where it was found.
# Entry Criteria: $program is a bare program name.
# Exit Status:    Returns the full path, or undef if not found.
# Side Effects:   Logs the location at debug level when --verbose is on.
sub _find_program :Private {
	my ($self, $program) = @_;

	my $path = which($program);
	if($path && $self->{verbose}) {
		$self->_log(debug => 'program_found', { params => [$program, $path] });
	}
	return $path;
}

# _reset_names
# Purpose:        Forget file names allocated by a previous run() so that
#                 running the same exporter twice gives the same names.
# Entry Criteria: None.
# Exit Status:    Returns $self.
# Side Effects:   Empties $self->{used_names}.
sub _reset_names :Private {
	my $self = shift;

	$self->{used_names} = {};
	return $self;
}

# _get_tables
# Purpose:        List the user tables in the database.
# Entry Criteria: _verify_dependencies() has run.
# Exit Status:    Returns an arrayref of table names, sorted; croaks if
#                 mdb-tables fails.
# Side Effects:   Runs mdb-tables.
sub _get_tables :Protected {
	my ($self, $database) = @_;

	# -1 puts one table per line, so names containing spaces survive;
	# "--" stops a database path starting with "-" being read as an option
	my $stdout = '';
	$self->_run_program($MDB_TABLES, ['-1', $END_OF_OPTIONS, $database], \$stdout);

	# \r? copes with mdbtools builds that emit CRLF line endings; a program
	# that printed nothing may leave $stdout undefined
	my @tables = sort grep { length($_) && !$self->_is_system_table($_) } split /\r?\n/, (defined($stdout) ? $stdout : '');
	return \@tables;
}

# _is_system_table
# Purpose:        Decide whether a table is Access's own rather than the user's.
# Entry Criteria: $table is a table name.
# Exit Status:    Returns 1 for system tables, 0 otherwise.
# Side Effects:   None.  Protected so that subclasses can widen the filter.
sub _is_system_table :Protected {
	my ($self, $table) = @_;

	return ($table =~ $SYSTEM_TABLE_RE) ? 1 : 0;
}

# _select_tables
# Purpose:        Apply the --table filter to the list of tables.
# Entry Criteria: $tables is the arrayref from _get_tables().
# Exit Status:    Returns an arrayref, in database (sorted) order.
# Side Effects:   Warns and logs about requested tables that do not exist.
sub _select_tables :Private {
	my ($self, $tables) = @_;

	return $tables unless $self->{tables};

	# Matching is exact, as mdb-export itself is case-sensitive
	my %available = map { $_ => 1 } @{$tables};
	my %wanted    = map { $_ => 1 } @{ $self->{tables} };

	my @missing = sort grep { !$available{$_} } keys %wanted;
	if(@missing) {
		$self->_warn('unknown_tables', { params => [join(', ', @missing)], count => scalar(@missing) });
	}

	return [ grep { $wanted{$_} } @{$tables} ];
}

# _make_output_dir
# Purpose:        Create the output directory (and parents) if necessary.
# Entry Criteria: Not in dry-run mode.
# Exit Status:    Returns $self; croaks if the directory cannot be created.
# Side Effects:   Creates directories.
sub _make_output_dir :Private {
	my $self = shift;

	my $dir = $self->{output_dir};
	return $self if -d $dir;

	# Ask File::Path to report errors rather than carp/croak on its own,
	# so the message can be translated and names the directory we wanted
	make_path($dir, { error => \my $errors });
	if(@{$errors} || !-d $dir) {
		# File::Path may also report a parent (e.g. "File exists" for a
		# plain file in the way); the reason for $dir itself, or failing
		# that the last one, is what explains the failure
		my ($mine) = grep { exists $_->{$dir} } @{$errors};
		my $detail = $mine ? $mine->{$dir} : (@{$errors} ? (values %{ $errors->[-1] })[0] : undef);
		$self->_croak_i18n('mkdir_failed', { params => [$dir, $detail || "$!"] });
	}
	return $self;
}

# _export_all
# Purpose:        Export each table, carrying on past individual failures.
# Entry Criteria: The output directory exists.
# Exit Status:    Returns the number of tables that failed.
# Side Effects:   Writes CSV files; prints progress; warns; logs.
sub _export_all :Private {
	my ($self, $database, $tables) = @_;

	my $total  = scalar @{$tables};
	my $failed = 0;

	# eval below would otherwise overwrite the caller's $@
	local $@;

	# An index loop, not each(), which shares the array's iterator with the
	# caller and would silently skip tables if it was already part-way
	foreach my $index (0 .. $#{$tables}) {
		my $table = $tables->[$index];
		# Progress goes to STDERR so that STDOUT can be redirected cleanly
		if($self->{progress}) {
			print STDERR $self->i18n('progress', { params => [$index + 1, $total, $table] }), "\n";
		}

		# One bad table should not stop the rest from being exported
		next if eval { $self->_export_table($database, $table); 1 };

		my $error = $@ || 'Unknown error';
		chomp $error;
		++$failed;
		$self->_warn('export_failed', { params => [$table, $error] });
	}

	$self->_log(info => 'summary', { params => [$total, $failed], count => $total });
	return $failed;
}

# _export_table
# Purpose:        Export one table to its CSV file.
# Entry Criteria: _verify_dependencies() and _make_output_dir() have run.
# Exit Status:    Returns $self; croaks on any failure, leaving no partial file.
# Side Effects:   Runs mdb-export (and mdb-count); creates or replaces a file.
sub _export_table :Protected {
	my ($self, $database, $table) = @_;

	my $outfile = File::Spec->catfile($self->{output_dir}, $self->_csv_filename($table));

	# Check before exporting so that we do not waste time on a big table
	# -l as well as -e: a dangling symlink is an existing entry too, and
	# must not be silently replaced
	if((-e $outfile || -l $outfile) && !$self->{overwrite}) {
		$self->_croak_i18n('output_exists', { params => [$outfile] });
	}

	# Write into a temporary file next to the target; it is deleted
	# automatically if anything below croaks
	my $tmp = File::Temp->new(DIR => $self->{output_dir}, TEMPLATE => $TEMP_TEMPLATE, UNLINK => 1);
	binmode $tmp, ':raw';

	if($self->{encoding} eq $ENC_CP1252) {
		$self->_export_transcoded($database, $table, $tmp);
	} else {
		# The BOM must reach the file before mdb-export starts writing to
		# the same descriptor, hence the explicit flush
		print {$tmp} $UTF8_BOM if $self->{encoding} eq $ENC_UTF8_BOM;
		$tmp->flush() or $self->_croak_i18n('write_failed', { params => [$outfile, "$!"] });
		$self->_run_program($MDB_EXPORT, [$END_OF_OPTIONS, $database, $table], $tmp);
	}

	$self->_install_file($tmp, $outfile);

	# Row counts are optional extras, reported only if asked for
	if($self->{show_counts}) {
		my $rows = $self->_count_rows($database, $table);
		$self->_log(info => 'exported_rows', { params => [$table, $outfile, $rows], count => $rows });
	} else {
		$self->_log(info => 'exported', { params => [$table, $outfile] });
	}
	return $self;
}

# _export_transcoded
# Purpose:        Export a table and convert it from UTF-8 to Windows-1252.
# Entry Criteria: $out is an open, raw, writable filehandle.
# Exit Status:    Returns $self; croaks on invalid UTF-8 or on a character
#                 that has no cp1252 equivalent (rather than silently
#                 replacing it with '?').
# Side Effects:   Runs mdb-export into a second temporary file.
sub _export_transcoded :Private {
	my ($self, $database, $table, $out) = @_;

	# Reading the spool changes $. and the evals change $@; keep the
	# caller's values
	local $.;
	local $@;

	# Spool to disk rather than memory, so huge tables do not exhaust RAM
	my $spool = File::Temp->new(DIR => $self->{output_dir}, TEMPLATE => $TEMP_TEMPLATE, UNLINK => 1);
	binmode $spool, ':raw';
	$self->_run_program($MDB_EXPORT, [$END_OF_OPTIONS, $database, $table], $spool);
	seek $spool, 0, 0;

	# Convert line by line; $. gives the user a line number to look at
	while(my $line = <$spool>) {
		my $chars = eval { Encode::decode('UTF-8', $line, FB_CROAK) };
		$self->_croak_i18n('invalid_utf8', { params => [$table, $.] }) unless defined $chars;

		my $bytes = eval { Encode::encode($ENC_CP1252, $chars, FB_CROAK) };
		$self->_croak_i18n('unmappable', { params => [$table, $., $ENC_CP1252] }) unless defined $bytes;

		print {$out} $bytes;
	}
	return $self;
}

# _install_file
# Purpose:        Move a finished temporary file to its final name.
# Entry Criteria: $tmp is a File::Temp holding the complete CSV.
# Exit Status:    Returns $self; croaks if the rename or chmod fails.
# Side Effects:   Replaces $outfile; the temporary file is no longer
#                 auto-deleted.
sub _install_file :Private {
	my ($self, $tmp, $outfile) = @_;

	# The eval must not overwrite the caller's $@
	local $@;

	# File::Temp creates files as 0600; give the CSV the permissions a
	# normal open() would have, i.e. 0666 less the umask
	my $ok = eval {
		close $tmp;
		chmod $FILE_MODE & ~umask(), $tmp->filename();
		rename $tmp->filename(), $outfile;
		1;
	};
	$self->_croak_i18n('write_failed', { params => [$outfile, _os_error($@)] }) unless $ok;

	$tmp->unlink_on_destroy(0);
	return $self;
}

# _count_rows
# Purpose:        Ask mdb-count how many rows a table has.
# Entry Criteria: $self->{programs}{'mdb-count'} is set.
# Exit Status:    Returns a non-negative integer; croaks if mdb-count fails.
# Side Effects:   Runs mdb-count.
sub _count_rows :Private {
	my ($self, $database, $table) = @_;

	my $stdout = '';
	$self->_run_program($MDB_COUNT, [$END_OF_OPTIONS, $database, $table], \$stdout);

	# mdb-count prints just the number, but be tolerant of whitespace and
	# of no output at all
	my ($rows) = (defined($stdout) ? $stdout : '') =~ /(\d+)/;
	return $rows || 0;
}

# _run_program
# Purpose:        Run an mdbtools program and check that it succeeded.
#                 Shared by every call to mdbtools, so that failures are
#                 reported consistently.
# Entry Criteria: $name is a key of $self->{programs}; $args is an arrayref;
#                 $stdout is a scalar ref or a filehandle for run3().
# Exit Status:    Returns $self; croaks if the program exits non-zero or
#                 dies from a signal.
# Side Effects:   Runs a child process; writes to $stdout; sets $?.
sub _run_program :Private {
	my ($self, $name, $args, $stdout) = @_;

	# run3 sets $?; keep the caller's value
	local $?;

	# A list (not a string) is passed, so no shell ever sees the file or
	# table name and quoting cannot be abused
	my $stderr = '';
	run3([$self->{programs}{$name}, @{$args}], \undef, $stdout, \$stderr);

	# Distinguish "never started" (-1) and a signal from an ordinary
	# non-zero exit status; $! only means something in the first case
	my ($status, $reason) = ($?, "$!");
	chomp $stderr;
	if($status == -1) {
		$self->_croak_i18n('program_not_run', { params => [$name, $reason] });
	}
	if($status & 127) {
		$self->_croak_i18n('program_signalled', { params => [$name, $status & 127] });
	}
	if($status) {
		$self->_croak_i18n('program_failed', { params => [$name, $status >> 8, $stderr] });
	}
	return $self;
}

# _csv_filename
# Purpose:        Turn a table name into a safe, unique CSV file name.
# Entry Criteria: $table is a table name (possibly empty).
# Exit Status:    Returns a file name (no directory) ending in ".csv".
# Side Effects:   Records the name in $self->{used_names}.
#
# Names are compared case-insensitively, because Windows and macOS file
# systems are, so "Orders" and "ORDERS" do not overwrite each other.
# The loop (rather than a single suffix) guarantees uniqueness even when
# another table is literally called "Orders_2".
sub _csv_filename :Protected {
	my ($self, $table) = @_;

	my $name = defined($table) ? $table : '';

	# Replace characters that are illegal somewhere, then strip leading
	# and trailing whitespace; Windows also silently drops trailing dots
	$name =~ s/$UNSAFE_CHARS_RE/_/g;
	$name =~ s/\A\s+//;
	$name =~ s/[\s.]+\z//;

	# Avoid hidden files, Windows device names and empty names
	$name =~ s/\A\./_/;
	$name = "_$name" if $name =~ $RESERVED_NAME_RE;
	$name = $UNNAMED unless length $name;

	my $used = $self->{used_names};
	my $file = $name . $CSV_SUFFIX;
	for(my $n = 2; exists $used->{lc $file}; $n++) {
		$file = "${name}_$n$CSV_SUFFIX";
	}
	$used->{lc $file} = 1;

	return $file;
}

# _dry_run
# Purpose:        Print the table -> file mapping without writing anything.
# Entry Criteria: $tables is the arrayref of selected tables.
# Exit Status:    Returns $self.
# Side Effects:   Prints to STDOUT; runs mdb-count when show_counts is on.
sub _dry_run :Private {
	my ($self, $database, $tables) = @_;

	# Only show the ROWS column when counts are actually available
	my $counts = $self->{show_counts};
	my $format = $counts
		? "%-${TABLE_COLUMN_WIDTH}s %${ROWS_COLUMN_WIDTH}s  %s\n"
		: "%-${TABLE_COLUMN_WIDTH}s %s\n";
	my @header = map { $self->i18n($_) } ($counts ? qw(column_table column_rows column_output) : qw(column_table column_output));

	# Underline the title to the length of whatever the translation is
	my $title = $self->i18n('dry_run_title');
	print "\n$title\n", '=' x length($title), "\n\n";
	printf $format, @header;
	print '-' x $RULE_WIDTH, "\n";

	foreach my $table (@{$tables}) {
		my @row = ($table);
		push @row, $self->_count_rows($database, $table) if $counts;
		printf $format, @row, $self->_csv_filename($table);
	}
	print "\n";

	return $self;
}

# _warn
# Purpose:        Warn the user and record the same text in the log.
# Entry Criteria: $key is a catalog key; $args an optional i18n() hashref.
# Exit Status:    Returns $self.
# Side Effects:   carp()s; logs at warn level.
sub _warn :Private {
	my ($self, $key, $args) = @_;

	$self->_carp_i18n($key, $args);
	return $self->_log(warn => $key, $args);
}

# _log
# Purpose:        Send a localised message to the logger, if there is one.
# Entry Criteria: $level is a logger method name (debug, info or warn).
# Exit Status:    Returns $self.
# Side Effects:   Calls $self->{logger}->$level().
sub _log :Private {
	my ($self, $level, $key, $args) = @_;

	my $logger = $self->{logger} or return $self;

	# Logging is secondary: a logger that dies (full disk, closed socket)
	# must not make a finished export look failed.  Say so once and stop
	# using it.
	local $@;
	if(!eval { $logger->$level($self->i18n($key, $args)); 1 }) {
		my $error = $@;
		chomp $error;
		delete $self->{logger};
		$self->_carp_i18n('log_failed', { params => [$error] });
	}
	return $self;
}

# _os_error
# Purpose:        Get a readable OS error from an autodie exception or string.
# Entry Criteria: $error is whatever eval left in $@.
# Exit Status:    Returns a string.
# Side Effects:   None.  A plain function, not a method.
sub _os_error :Private {
	my $error = shift;

	# autodie::exception keeps the original $! for us
	my $text = (ref($error) && $error->can('errno')) ? $error->errno() : "$error";
	chomp $text;
	return $text;
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * mdbtools is expected to give UTF-8.  This is what it does when it is
built with iconv (the normal case).  If the C<MDB_ICONV> environment
variable selects another character set, C<cp1252> conversion reports
invalid UTF-8.

=item * C<cp1252> conversion stops at the first character that Windows-1252
does not have, and that table fails.  It never writes C<?> instead.  Line
numbers count lines in the file, so a text field that contains line
breaks covers several lines.

=item * Checking that a file already exists and renaming the new file into
place are two separate steps.  If another program creates the same file
between them, that file is replaced.

=item * File names are made safe for Windows, macOS and Unix, but are not
shortened.  Access table names are at most 64 characters, which is well
within normal limits.

=item * Row counts need one extra C<mdb-count> run for each table.

=item * The private and protected methods are protected by L<Sub::Private>
and L<Sub::Protected> only when this module is loaded with C<use>.  When
C<$ENV{HARNESS_ACTIVE}> is set (under C<prove>), the checks are turned
off so that tests can call these methods.

=back

=head1 SEE ALSO

L<App::Access2CSV>, L<App::Access2CSV::I18N>, L<https://github.com/mdbtools/mdbtools>

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 LICENSE AND COPYRIGHT

This program is released under the same terms as Perl itself.

=head1 FORMAL SPECIFICATION

These schemas use the Z notation.  C<?> marks an input, C<!> an output,
C<'> the state after the operation, "Delta" a changed state and "Xi" an
unchanged state.  You do not need to read this section to use the module.

	┌─ Exporter ─────────────────────────────────────────────────
	│ settings : SETTING ⇸ VALUE
	│ used_names : ℙ FILENAME
	│ programs : PROGRAM ⇸ PATH
	├────────────────────────────────────────────────────────────
	│ settings(encoding) ∈ {utf8, utf8-bom, cp1252}
	│ ∀ n₁, n₂ : used_names • lower(n₁) = lower(n₂) ⇒ n₁ = n₂
	└────────────────────────────────────────────────────────────

=head2 new

	┌─ NewExporter ──────────────────────────────────────────────
	│ Exporter'
	│ args? : SETTING ⇸ VALUE
	├────────────────────────────────────────────────────────────
	│ dom args? ⊆ dom NEW_SCHEMA
	│ ∀ k : dom args? • valid(NEW_SCHEMA(k), args?(k))
	│ settings' = DEFAULTS ⊕ { k : dom args? | args?(k) ≠ undef • k ↦ args?(k) }
	│ used_names' = ∅
	│ programs' = ∅
	└────────────────────────────────────────────────────────────

=head2 run

	┌─ Run ──────────────────────────────────────────────────────
	│ ΔExporter ; ΔFileSystem
	│ database? : PATH ; status! : {0, 1}
	│ all, selected : iseq TABLE ; failed : ℙ TABLE
	├────────────────────────────────────────────────────────────
	│ database? ∈ readableFiles
	│ {mdb-tables, mdb-export} ⊆ dom PATH
	│ all = sort({ t : tablesOf(database?) | ¬ system(t) })
	│ selected = (if tables ∉ dom settings then all
	│             else all ↾ ran settings(tables))
	│ settings(dry_run) ⇒ files' = files ∧ status! = 0
	│ ¬ settings(dry_run) ⇒
	│   failed = { t : ran selected | ¬ exported(t) } ∧
	│   (∀ t : ran selected \ failed •
	│      files'(output_dir / csvName(t)) = encode(encoding, csv(t))) ∧
	│   (∀ t : failed • files'(output_dir / csvName(t)) = files(output_dir / csvName(t))) ∧
	│   status! = (if failed = ∅ then 0 else 1)
	└────────────────────────────────────────────────────────────

	┌─ RunFatal ─────────────────────────────────────────────────
	│ ΞFileSystem
	│ database? : PATH ; error! : MESSAGE
	├────────────────────────────────────────────────────────────
	│ database? ∉ readableFiles ∨ {mdb-tables, mdb-export} ⊈ dom PATH
	│   ∨ mdbTablesFails(database?)
	│ error! ≠ ∅
	└────────────────────────────────────────────────────────────

	ExporterRun ≙ Run ∨ RunFatal

=head1 STATE DIAGRAM

The life of one exporter object, and of one call to C<run>.  Each box is
a state.  Each arrow shows what causes the change, and what happens on
the way.

	            new(%settings)
	            action: validate settings, apply defaults
	                  |
	                  v
	          +----------------+ <------------------------------------+
	          |     READY      |                                      |
	          +----------------+                                      |
	                  | run($database)                                |
	                  v                                               |
	          +----------------+  database missing or unreadable,    |
	          |   CHECKING     |  mdb-tables/mdb-export not found    |
	          | database and   |------------------------------+       |
	          | programs       |                              |       |
	          +----------------+                              |       |
	                  | OK; action: forget old file names;    |       |
	                  |   warn if mdb-count is missing and    |       |
	                  |   switch show_counts off              |       |
	                  v                                       |       |
	          +----------------+  mdb-tables fails            |       |
	          |    LISTING     |------------------------------+       |
	          | tables         |                              |       |
	          +----------------+                              |       |
	                  | action: drop system tables, sort,     |       |
	                  |   filter by "tables", warn about      |       |
	                  |   unknown names                       |       |
	          +-------+--------+                              |       |
	 dry_run  |                | not dry_run                  |       |
	          v                v                              |       |
	 +----------------+  +----------------+  mkdir fails      |       |
	 |    DRY RUN     |  |   PREPARING    |-------------------+       |
	 | print the list |  | output folder  |                   |       |
	 | to STDOUT      |  +----------------+                   |       |
	 +----------------+          | folder exists             v       |
	          |                  v                    +--------------+ |
	          |          +----------------+           |    FATAL     | |
	          |          |   EXPORTING    |<--+       | croak; no    | |
	          |          | one table      |   |       | file written |-+
	          |          +----------------+   |       +--------------+
	          |            |           |      | next table
	          |   success  |           | failure (file exists,
	          |   action:  |           |   mdb-export fails, bad
	          |   rename   |           |   character, ...)
	          |   temp file|           |   action: delete temp file,
	          |   into     |           |   carp, log, count failure
	          |   place,   |           |      |
	          |   log      |           +------+
	          |            +------------------+
	          |                  | no tables left
	          |                  v
	          |          +----------------+
	          |          |    SUMMARY     |  action: log "Processed N tables,
	          |          +----------------+          M failed"
	          |             |          |
	          v             v          v
	      return 0      return 0    return 1
	    (to READY)     (M = 0)      (M > 0)
	                  (to READY)   (to READY)

=cut
