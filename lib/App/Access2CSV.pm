package App::Access2CSV;

use strict;
use warnings;
use autodie qw(:all);

# Sub::Private must be in enforce mode before it is loaded, so that
# private class methods still work through $class->method dispatch
BEGIN { $Sub::Private::config{mode} = 'enforce' }

# Inherit i18n() and the protected _croak_i18n/_carp_i18n helpers
use parent 'App::Access2CSV::I18N';

use App::Access2CSV::Exporter;
use Fcntl qw(O_APPEND O_CREAT O_WRONLY);
use Getopt::Long qw(GetOptionsFromArray);
use Log::Abstraction;
use Pod::Usage qw(pod2usage);
use Readonly;
use Return::Set qw(set_return);
use Sub::Private;

our $VERSION = '0.001.0';

# Stop Carp from reporting errors against the access-control wrappers
our @CARP_NOT = qw(Sub::Private Sub::Protected App::Access2CSV::I18N);

# Exit statuses, documented in the POD below
Readonly::Scalar my $EXIT_OK      => 0;
Readonly::Scalar my $EXIT_FAILURE => 1;
Readonly::Scalar my $EXIT_USAGE   => 2;
Readonly::Scalar my $EXIT_FATAL   => 3;

# Pod::Usage verbosity levels for --help and --man, and for usage errors
Readonly::Scalar my $POD_SYNOPSIS => 0;
Readonly::Scalar my $POD_OPTIONS  => 1;
Readonly::Scalar my $POD_FULL     => 2;

# Log levels: --verbose adds the debug messages
Readonly::Scalar my $LOG_LEVEL         => 'info';
Readonly::Scalar my $LOG_LEVEL_VERBOSE => 'debug';

# Command-line defaults; the flat layout is compatible with Object::Configure
Readonly::Hash my %DEFAULTS => (
	output_dir  => '.',
	overwrite   => 0,
	verbose     => 0,
	dry_run     => 0,
	show_counts => 0,
	progress    => 1,
	encoding    => 'utf8',
	log         => 'access2csv.log',
);

=encoding utf8

=head1 NAME

App::Access2CSV - Export the tables of a Microsoft Access database to CSV files

=head1 VERSION

Version 0.001.0

=head1 SYNOPSIS

	# Export every table to the current directory
	access2csv shop.accdb

	# See what would be written, with row counts, without writing anything
	access2csv --dry-run --show-counts shop.accdb

	# Export only two tables, into a folder called "exports"
	access2csv --output-dir exports --table Customers --table Orders shop.mdb

	# Make files that Excel opens correctly, replace old files, no log file
	access2csv --encoding utf8-bom --overwrite --no-log shop.accdb

	# Nightly job: quiet, with a log in a fixed place, and stop on failure
	access2csv --no-progress --log /var/log/access2csv.log \
		--output-dir /srv/exports --overwrite shop.accdb || exit 1

=head1 DESCRIPTION

Microsoft Access keeps its data in C<.mdb> or C<.accdb> files.
C<access2csv> reads one of these files and writes one CSV file
(comma-separated values, a plain-text table) for each table in it.

It does not read the Access file itself.  It runs three small programs
from the free B<mdbtools> package:

=over 4

=item * C<mdb-tables> - to get the list of tables

=item * C<mdb-export> - to get the data of each table as CSV

=item * C<mdb-count> - to count rows (only when you use B<--show-counts>)

=back

These programs must be installed and must be in your C<PATH>.

Access also keeps its own internal tables in the file.  Their names start
with C<MSys>, C<USys> or C<~>.  They are skipped.

=head2 How the CSV files are named

Each file has the name of its table plus C<.csv>, for example
C<Orders.csv>.  Some characters are not allowed in file names on some
computers (C<< < > : " / \ | ? * >> and control characters).  They are
changed to C<_>, and so are invisible text-direction controls (such as
U+202E, "right-to-left override"), which could make a file name look
like something else.  Spaces and dots at the end, and spaces at the start,
are removed.  A name such as C<CON> or C<NUL> (reserved on Windows) gets a
C<_> in front.  An empty name becomes C<unnamed>.

If two tables would get the same file name, the second one gets C<_2>,
the third C<_3>, and so on.  Upper and lower case count as the same here,
because Windows and macOS treat C<Orders.csv> and C<ORDERS.csv> as one file.

=head2 How files are written

Each file is first written to a hidden temporary file (its name starts
with C<.access2csv->) in the output directory.  Only when it is complete
is it renamed to its real name.  So if something goes wrong, you never
get a half-written CSV file, and an old file is only replaced by a
complete new one.

=head1 USING FROM PERL

The program is a very thin wrapper.  You can call the same code from Perl:

	use App::Access2CSV;

	my $status = App::Access2CSV->run('--no-log', '--output-dir', 'out', 'shop.accdb');

For more control, use L<App::Access2CSV::Exporter> directly.

=head1 OPTIONS

=over 4

=item B<--output-dir> I<DIR>

The folder to write the CSV files to.  It is created if it does not exist.
Default: the current folder.

=item B<--table> I<NAME>

Export only this table.  You can use this option more than once.
Names must match exactly, including upper and lower case.  A name that is
not in the database gives a warning.

=item B<--overwrite>

Replace CSV files that already exist.  Without this option, a table whose
CSV file already exists is not exported, and it counts as a failure.

=item B<--verbose>

Write more detail to the log (where each mdbtools program was found).
Also show the Perl file and line number in fatal error messages.

=item B<--dry-run>

Only print a list of the tables and the file names they would get.
Nothing is written.  The output folder is not created.

=item B<--show-counts>

Show the number of rows of each table: in the dry-run list, and in the
log.  This needs C<mdb-count>.  Without it you get a warning, and the
export goes on without counts.

=item B<--no-progress>

Do not print the C<[1/5] Customers> progress lines.  (These lines go to
standard error, not standard output.)

=item B<--encoding> I<utf8|utf8-bom|cp1252>

The character encoding of the CSV files.  See L</ENCODING>.
Default: C<utf8>.

=item B<--log> I<FILE>

Add log messages to the end of I<FILE>.  Default: F<access2csv.log> in
the current folder.  An empty name (C<--log ''>) means no log.  I<FILE>
must not be a symbolic link (see L</SECURITY>).

=item B<--no-log>

Do not write a log file.

=item B<--help>, B<-h>

Print the synopsis and the options, then stop.

=item B<--man>

Print this whole manual, then stop.

=back

=head1 EXIT STATUS

The program ends with one of these numbers.  Scripts can test it.

	0  Every selected table was exported.  Also used for --dry-run,
	   --help and --man.
	1  At least one table was not exported.  The other tables were.
	2  The command line was wrong, for example an unknown option or no
	   database name.
	3  A fatal error happened before any table was exported, for example
	   the database does not exist or mdbtools is not installed.

=head1 ENCODING

=head2 The data in the CSV files

mdbtools gives the table data as UTF-8, the encoding that can hold every
character, including accented letters, Chinese and Japanese text, and
emoji.

=over 4

=item * C<utf8> (the default) - the data is copied exactly as mdbtools
gives it.  Every character, including emoji, is kept.

=item * C<utf8-bom> - the same, plus three bytes at the very start of each
file (a "byte order mark").  These bytes tell Microsoft Excel that the file
is UTF-8.  Without them, Excel may show accented letters wrongly.  Some
other programs show the mark as strange characters in the first column
name.

=item * C<cp1252> - Windows-1252, an old Western European encoding.  It has
only 256 characters: English letters, most Western European accented
letters, and a few symbols such as the Euro sign.  It has no Greek,
Cyrillic, Chinese, Japanese or emoji.  If a table contains a character
that Windows-1252 cannot hold, that table is B<not> exported, and the
error message gives the line number.  Nothing is silently replaced.

=back

=head2 Names on the command line

Database paths, folder names, log file names and table names are used
exactly as the operating system gives them to the program (as bytes).
On Linux and macOS, where the terminal uses UTF-8, names with accented
letters, non-Latin scripts and emoji work.  On Windows, the command line
uses the system code page, so names outside that code page may not work.

=head2 Messages

All messages that the program prints and logs are in plain ASCII English.

=head1 ENVIRONMENT

=over 4

=item C<PATH>

Used to find C<mdb-tables>, C<mdb-export> and C<mdb-count>.  Only
absolute folders in C<PATH> are used: relative entries such as C<.> are
ignored, so a program planted in the current folder is never run.

=item C<LANGUAGE>, C<LC_ALL>, C<LC_MESSAGES>, C<LANG>

Choose the language of messages (see L<App::Access2CSV::I18N>).  Only the
language code at the start is used; any other value means English.

=item C<MDB_ICONV>

Not read by this program, but by mdbtools: it sets the character set
mdbtools converts to.  Leave it unset, so that the output is UTF-8.

=back

=head1 SECURITY

The program treats the database as untrusted: an Access file received
from someone else may contain table names and data designed to cause
harm.

=over 4

=item * B<No shell, no option injection.>  Programs are run directly
(never through a shell), and table and file names are passed after a
C<--> marker, so names containing C<; | $( ) `> or starting with C<->
are only ever names.

=item * B<No planted programs.>  Relative C<PATH> entries are ignored
(see L</ENVIRONMENT>).

=item * B<Safe file names.>  Table names cannot place a file outside the
output folder, and control characters - including invisible
text-direction controls and C1 controls - are replaced by C<_>.

=item * B<Safe terminal and log output.>  Table names and mdbtools error
text are printed with control characters shown as escapes such as
C<\x1B>.  So a table name cannot retitle or clear your terminal, hide
text, or forge lines in the log.

=item * B<No writing through symbolic links.>  If the log file is a
symbolic link (for example one planted in a shared folder such as
F</tmp>), the program stops instead of writing to the file it points at.
Existing CSV files that are links are replaced, never written through.

=item * B<Spreadsheet formulas are NOT neutralised.>  A value such as
C<=cmd|' /C calc'!A0> is copied into the CSV exactly as it is in the
database, because changing data would corrupt genuine values.  Some
spreadsheet programs run such formulas when a CSV is opened.  Do not open
CSV files exported from an untrusted database in a spreadsheet without
checking them, or import them as text.

=back

=head1 COMMON PITFALLS

=over 4

=item * B<A log file appears in the current folder.>  By default the log is
F<access2csv.log> in the folder you run the program from.  Use B<--log> to
choose another place, or B<--no-log>.

=item * B<The second run fails.>  If the CSV files already exist, each table
fails (exit status 1) unless you give B<--overwrite>.

=item * B<--table does not find my table.>  Table names are case-sensitive:
C<--table orders> does not match C<Orders>.  Use B<--dry-run> to see the
exact names.

=item * B<A file is called Orders_2.csv.>  Two tables had names that give
the same file name (for example C<Orders> and C<ORDERS>, or C<A/B> and
C<A:B>).

=item * B<Progress lines appear even though I redirected the output.>
Progress lines go to standard error.  Use B<--no-progress>, or redirect
standard error too (C<2E<gt>/dev/null>).

=item * B<run() does not end the program.>  When calling from Perl,
C<< App::Access2CSV->run(...) >> returns the exit status.  It does not
call C<exit>.  Write C<< exit App::Access2CSV->run(@ARGV) >> if you want
the program to end.

=item * B<Pass a list, not an array reference.>  Write
C<< App::Access2CSV->run(@args) >>, not C<< App::Access2CSV->run(\@args) >>.

=back

=head1 METHODS

=head2 run

=head3 Purpose

This is the whole C<access2csv> program.  It reads the command-line
options, opens the log, and runs an L<App::Access2CSV::Exporter>.

=head3 Arguments

The command-line arguments, as a list of strings (normally C<@ARGV>).
Your array is copied first, so it is not changed.

=head3 Returns

A number from 0 to 3, as described in L</EXIT STATUS>.
C<run> never calls C<exit> itself.

=head3 Side Effects

=over 4

=item * Everything that L<App::Access2CSV::Exporter/run> does: it creates
the output folder, writes CSV files, and prints progress to standard error.

=item * It prints help or usage text (help to standard output, usage errors
to standard error).

=item * It prints a fatal error, if there is one, to standard error as one
line that starts with C<access2csv:>.

=item * It creates or adds to the log file, unless logging is off.

=item * It leaves your C<$@>, C<$!>, C<$_> and any pending C<alarm> as
they were.

=back

=head3 Usage

	exit App::Access2CSV->run(@ARGV);

=head3 EXAMPLE

	use App::Access2CSV;

	# Export to ./out without a log file, then check what happened
	my $status = App::Access2CSV->run('--output-dir', 'out', '--no-log', 'shop.accdb');

	if($status == 0) {
		print "All tables were exported\n";
	} elsif($status == 1) {
		print "Some tables could not be exported\n";
	} elsif($status == 2) {
		print "The arguments were wrong\n";
	} else {
		print "Nothing was exported\n";
	}

=head3 API SPECIFICATION

=head4 Input

	{
		argv => {
			type         => 'arrayref',
			optional     => 1,
			element_type => 'string',
			description  => 'Command-line arguments, passed as a list',
		},
	}

Valid and invalid values (tested in F<t/domain.t>):

	database names  exactly 1; 0 or 2 or more give exit status 2
	--encoding      utf8, utf8-bom or cp1252; anything else gives exit 3
	--table         0 times (all tables), once, or many times; names
	                may be non-ASCII
	--log           a file name; '' means no log, like --no-log

=head4 Output

	{
		type => 'integer',
		min  => 0,
		max  => 3,
	}

=head3 MESSAGES

	+-------------------------------------+-------------------------------+------------------------------+
	| Message                             | Meaning                       | What to do                   |
	+-------------------------------------+-------------------------------+------------------------------+
	| Unknown option: X (exit 2)          | X is not an option of this    | See --help                   |
	|                                     | program                       |                              |
	| Option X requires an argument       | An option such as --log was   | Give a value after it        |
	|  (exit 2)                           | the last word                 |                              |
	| Missing database filename (exit 2)  | No database name was given,   | Give exactly one database    |
	|                                     | it was empty, or more than    |                              |
	|                                     | one was given                 |                              |
	| access2csv: Cannot open log file F: | The log file cannot be        | Use --log with another file, |
	|  E (exit 3)                         | written; E is the reason from | or --no-log                  |
	|                                     | the operating system, "no     |                              |
	|                                     | logger was created", or "it   |                              |
	|                                     | is a symbolic link"           |                              |
	| access2csv: MESSAGE (exit 3)        | Any fatal error from the      | See MESSAGES in              |
	|                                     | exporter                      | App::Access2CSV::Exporter    |
	+-------------------------------------+-------------------------------+------------------------------+

=head3 PSEUDOCODE

	options := default settings
	read the command line into options
	if the command line is wrong: print usage, return 2
	if --help or --man: print the documentation, return 0
	if there is not exactly one database name: print usage, return 2
	try:
		open the log, unless logging is off
		status := new Exporter(options).run(database)
	if that failed:
		print "access2csv: <reason>" to standard error
		status := 3
	return status

=cut

sub run {
	my ($class, @argv) = @_;

	# Option parsing, file tests and the eval below would otherwise leave
	# their marks in the caller's $@ and $!
	local ($@, $!);

	# Parsing may already decide the outcome (--help, bad options, ...)
	my %opt = %DEFAULTS;
	my $status = $class->_parse_options(\@argv, \%opt);

	if(!defined $status) {
		# Any croak from here on is a fatal error: report it, don't die
		$status = eval {
			my $logger = $class->_make_logger(\%opt);
			my $exporter = App::Access2CSV::Exporter->new(
				map({ $_ => $opt{$_} } grep { $_ ne 'log' } keys %opt),
				($logger ? (logger => $logger) : ()),
			);
			$exporter->run($argv[0]);
		};
		$status = $class->_report_fatal($@, $opt{verbose}) unless defined $status;
	}

	return set_return($status, { type => 'integer', min => $EXIT_OK, max => $EXIT_FATAL });
}

# _parse_options
# Purpose:        Turn the command line into settings.
# Entry Criteria: $argv is an arrayref (modified in place: options are
#                 removed, leaving the positional arguments); $opt is a
#                 hashref of defaults.
# Exit Status:    Returns undef if the export should go ahead, otherwise
#                 the exit status to return straight away.
# Side Effects:   Fills in $opt; prints help, the manual or usage text.
sub _parse_options :Private {
	my ($class, $argv, $opt) = @_;

	my $help = 0;
	my $parsed = GetOptionsFromArray(
		$argv,
		'output-dir=s' => \$opt->{output_dir},
		'table=s@'     => \$opt->{tables},
		'overwrite!'   => \$opt->{overwrite},
		'verbose!'     => \$opt->{verbose},
		'dry-run!'     => \$opt->{dry_run},
		'show-counts!' => \$opt->{show_counts},
		'progress!'    => \$opt->{progress},
		'encoding=s'   => \$opt->{encoding},
		'log=s'        => \$opt->{log},
		'no-log'       => sub { $opt->{log} = undef },
		'help|h'       => sub { $help = $POD_OPTIONS },
		'man'          => sub { $help = $POD_FULL },
	);

	# Only one of these applies; the first match decides the exit status.
	# Getopt::Long has already warned about any unknown option.
	return $class->_usage($EXIT_USAGE, $POD_SYNOPSIS) unless $parsed;
	return $class->_usage($EXIT_OK, $help) if $help;
	# An empty or undefined name is as good as no name at all.  length()
	# of an empty string is 0, so one length test covers "", and "// ''"
	# turns undef into "" first.
	if(@{$argv} != 1 || !length($argv->[0] // '')) {
		return $class->_usage($EXIT_USAGE, $POD_SYNOPSIS, $class->i18n('missing_database'));
	}
	return;
}

# _usage
# Purpose:        Print documentation from this module's POD.
# Entry Criteria: $status is the exit status to return; $verbose is a
#                 Pod::Usage verbosity; $message is an optional error.
# Exit Status:    Returns $status.
# Side Effects:   Prints to STDOUT (help) or STDERR (errors).
sub _usage :Private {
	my ($class, $status, $verbose, $message) = @_;

	# The POD lives here, not in bin/access2csv, so point Pod::Usage at
	# this file; NOEXIT keeps run() testable
	pod2usage(
		-input   => __FILE__,
		-verbose => $verbose,
		-exitval => 'NOEXIT',
		-output  => $status == $EXIT_OK ? \*STDOUT : \*STDERR,
		(defined($message) ? (-message => $message) : ()),
	);
	return $status;
}

# _make_logger
# Purpose:        Create the log, unless logging is switched off.
# Entry Criteria: $opt->{log} is a file name, or undef/'' for no log.
# Exit Status:    Returns a Log::Abstraction object or undef; croaks if the
#                 file cannot be appended to.
# Side Effects:   Creates the log file if it does not exist.
sub _make_logger :Private {
	my ($class, $opt) = @_;

	return unless length($opt->{log} // '');

	# Log::Abstraction silently ignores an unwritable file, which would lose
	# the log without telling anyone, so prove that we can append first.
	# The eval must not overwrite the caller's $@.
	my $file = $opt->{log};

	# Never write through a symbolic link: in a shared folder such as /tmp
	# anyone could plant "access2csv.log" pointing at a file of yours
	if(-l $file) {
		$class->_croak_i18n('log_open_failed', { params => [$file, $class->i18n('log_is_symlink')] });
	}

	# O_NOFOLLOW (where the OS has it) closes the gap between the -l test
	# above and the open, when the probe itself creates the file
	local $@;
	eval {
		sysopen my $fh, $file, O_WRONLY | O_APPEND | O_CREAT | _no_follow();
		close $fh;
		1;
	} or $class->_croak_i18n('log_open_failed', { params => [$file, (ref($@) && $@->can('errno')) ? $@->errno() : "$!"] });

	my $logger = Log::Abstraction->new(
		logger => $file,
		level  => $opt->{verbose} ? $LOG_LEVEL_VERBOSE : $LOG_LEVEL,
	);

	# The user asked for a log; carrying on without one would silently
	# break that promise
	$logger or $class->_croak_i18n('log_open_failed', { params => [$file, $class->i18n('logger_unavailable')] });
	return $logger;
}

# _no_follow
# Purpose:        The O_NOFOLLOW open flag, or 0 where the OS lacks it.
# Entry Criteria: None.
# Exit Status:    Returns an integer flag.
# Side Effects:   None.
sub _no_follow :Private {
	return eval { Fcntl::O_NOFOLLOW() } || 0;
}

# _report_fatal
# Purpose:        Tell the user why the program stopped.
# Entry Criteria: $error is the exception from eval; $verbose is the
#                 --verbose flag.
# Exit Status:    Returns the fatal exit status.
# Side Effects:   Prints to STDERR.
sub _report_fatal :Private {
	my ($class, $error, $verbose) = @_;

	# Carp appends " at FILE line N."; that is noise for a command-line
	# user, but useful when debugging, so keep it with --verbose
	my $text = length($error // '') ? "$error" : 'Unknown error';
	# The file name may contain spaces ("My Documents"), so it cannot be
	# matched as \S+.  Instead: " at ", then the shortest run of characters
	# that does not contain another " at ", then " line N." at the very
	# end.  The (?! at ) guard keeps this linear: each attempt stops at the
	# next " at ", so no character is scanned by more than one attempt.
	$text =~ s/
		[ ] at [ ]                  # Carp's separator
		(?: (?! [ ] at [ ] ) . )*?  # the file name: anything but another " at "
		[ ] line [ ] \d+ \.?        # " line 42."
		\n? \z                      # at the very end
	//x unless $verbose;
	chomp $text;

	# The reason may quote a hostile table name or file name: escape it
	print STDERR $class->_printable($class->i18n('fatal', { params => [$text] })), "\n";
	return $EXIT_FATAL;
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * The real work is done by the external mdbtools programs.  Their
bugs, and their CSV style (quoting, date format, binary columns), are
passed on unchanged.  No maintained CPAN module can read C<.accdb> files,
so there is no pure-Perl alternative today.

=item * Messages that come from L<Getopt::Long>, L<Params::Validate::Strict>
and L<autodie> are not translated.

=item * The default log file is created in the current folder, which may
surprise users.

=item * Settings come from the command line only.  C<%DEFAULTS> is laid out
so that L<Object::Configure> could read them from a configuration file,
but this is not connected yet.

=back

=head1 SEE ALSO

L<App::Access2CSV::Exporter>, L<App::Access2CSV::I18N>, L<Log::Abstraction>,
L<https://github.com/mdbtools/mdbtools>

=over 4

=item * L<Test Dashboard|https://nigelhorne.github.io/App-access2csv/coverage/>

=back

=head1 FORMAL SPECIFICATION

These schemas use the Z notation.  C<?> marks an input and C<!> an output.
You do not need to read this section to use the program.

=head2 run

	┌─ Run ──────────────────────────────────────────────────────
	│ argv? : seq STRING ; status! : 0 ‥ 3
	│ opts : OPTION ⇸ VALUE ; rest : seq STRING
	├────────────────────────────────────────────────────────────
	│ (opts, rest) = getopt(DEFAULTS, argv?)
	│ ¬ parsed(argv?) ⇒ status! = 2
	│ parsed(argv?) ∧ help ∈ dom opts ⇒ status! = 0
	│ parsed(argv?) ∧ help ∉ dom opts ∧ #rest ≠ 1 ⇒ status! = 2
	│ parsed(argv?) ∧ help ∉ dom opts ∧ #rest = 1 ⇒
	│   (fatal(Exporter.Run(head rest)) ⇒ status! = 3) ∧
	│   (¬ fatal(Exporter.Run(head rest)) ⇒
	│        status! = Exporter.Run(head rest).status!)
	└────────────────────────────────────────────────────────────

=head2 Printable output

Every message shown on the terminal or written to the log first passes
through this filter.  C<CTRL> is the set of control characters: C0
except tab, DEL, C1 and the text-direction controls.

	┌─ Printable ────────────────────────────────────────────────
	│ text? : seq CHAR ; shown! : seq CHAR
	├────────────────────────────────────────────────────────────
	│ shown! = ⁀/ ⟨ c : text? • (if c ∈ CTRL then escape(c) else ⟨c⟩) ⟩
	│ ran shown! ∩ CTRL = ∅
	└────────────────────────────────────────────────────────────

=head1 STATE DIAGRAM

One call of C<run>, from start to exit status.  Each box is a state.
Each arrow shows what moves the program to the next state, and what
happens on the way.

	                  run(@argv)
	                      |
	                      v
	              +---------------+
	              |    PARSING    |  read options into the settings
	              +---------------+
	               |      |      |
	 bad option or |      |      | --help / --man
	 missing value |      |      | action: print documentation to STDOUT
	 or not exactly|      |      v
	 one database  |      |   +--------+
	 action: print |      |   |  HELP  |---> return 0
	 usage to      |      |   +--------+
	 STDERR        v      |
	      +-------------+ | options OK, one database
	      | USAGE ERROR | |
	      +-------------+ v
	          |   +------------------+
	 return 2 <---|  OPENING LOG     |  skipped with --no-log
	              +------------------+
	               |               |
	               | log is        | log cannot be opened
	               | writable      | (croak)
	               v               |
	      +------------------+     |
	      | EXPORTING        |     |
	      | (Exporter->run,  |     |
	      |  see its STATE   |     |
	      |  DIAGRAM)        |     |
	      +------------------+     |
	       |      |      |         |
	all    |      | some | fatal   |
	tables |      | table| error   |
	OK, or |      |failed| (croak) |
	dry run|      |      v         v
	       |      |   +------------------+
	       |      |   |      FATAL       |  action: print "access2csv: <reason>"
	       |      |   +------------------+          to STDERR
	       v      v            |
	  return 0  return 1   return 3

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.

=cut
