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
use Getopt::Long qw(GetOptionsFromArray);
use Log::Abstraction;
use Pod::Usage qw(pod2usage);
use Readonly;
use Return::Set qw(set_return);
use Sub::Private;

our $VERSION = '0.001';

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

Version 0.001

=head1 SYNOPSIS

	access2csv database.accdb

	access2csv --dry-run --show-counts database.accdb

	access2csv --output-dir exports --table Customers --table Orders database.mdb

	access2csv --encoding utf8-bom --overwrite --no-log database.accdb

=head1 DESCRIPTION

C<access2csv> writes one CSV file per user table of an Access
(C<.mdb> / C<.accdb>) database, using the mdbtools programs
C<mdb-tables> and C<mdb-export>, which must be in your C<PATH>.
C<mdb-count> is also used if you ask for row counts.

Access's own system tables (C<MSys*>, C<USys*> and C<~*>) are skipped.
Each file is named after its table, with characters that are illegal in
file names replaced by C<_>; if two tables would map to the same file
name (ignoring case), later ones get C<_2>, C<_3>, ... suffixes.

=head1 OPTIONS

=over 4

=item B<--output-dir> I<DIR>

Directory to write the CSV files to; created if necessary.  Default: the
current directory.

=item B<--table> I<NAME>

Export only this table.  May be given more than once.  Names are
case-sensitive; unknown names produce a warning.

=item B<--overwrite>

Replace CSV files that already exist.  Without it, such tables fail.

=item B<--verbose>

Log where the mdbtools programs were found, and show file and line
numbers in fatal error messages.

=item B<--dry-run>

List the tables and the files they would be written to, then stop.
Nothing is created, not even the output directory.

=item B<--show-counts>

Show row counts in the dry-run listing and in the log.  Needs
C<mdb-count>.

=item B<--no-progress>

Do not print C<[n/total] table> progress lines to STDERR.

=item B<--encoding> I<utf8|utf8-bom|cp1252>

Character encoding of the CSV files.  C<utf8-bom> adds a byte order mark,
which helps Excel recognise UTF-8.  C<cp1252> is Windows-1252; a table
containing a character with no Windows-1252 equivalent fails.
Default: C<utf8>.

=item B<--log> I<FILE>

Append a log to I<FILE>.  Default: F<access2csv.log> in the current
directory.

=item B<--no-log>

Do not write a log file.

=item B<--help>

Print the synopsis and options, then exit.

=item B<--man>

Print the full manual, then exit.

=back

=head1 EXIT STATUS

	0  every selected table was exported (or --dry-run / --help / --man)
	1  at least one table could not be exported
	2  the command line was invalid
	3  a fatal error stopped the export before it began, e.g. the database
	   is missing or mdbtools is not installed

=head1 METHODS

=head2 run

=head3 Purpose

The whole of the C<access2csv> program: parse the command line, set up
logging and run an L<App::Access2CSV::Exporter>.

=head3 Arguments

The command-line arguments, as a list (normally C<@ARGV>).  The list is
copied, so the caller's array is not changed.

=head3 Returns

The exit status described in L</EXIT STATUS>.  C<run> never calls
C<exit> itself, which makes it easy to test.

=head3 Side Effects

Everything the exporter does (see L<App::Access2CSV::Exporter/run>), plus:
prints help or usage text, prints fatal errors to STDERR and appends to
the log file.

=head3 Usage

	exit App::Access2CSV->run(@ARGV);

=head3 EXAMPLE

	use App::Access2CSV;

	# Export to ./out without a log file, and act on the result
	my $status = App::Access2CSV->run('--output-dir', 'out', '--no-log', 'shop.accdb');
	if($status == 1) {
		print "Some tables could not be exported\n";
	}

=head3 API SPECIFICATION

=head4 Input

	{
		argv => {
			type     => 'arrayref',
			optional => 1,
			element_type => 'string',
			description  => 'Command-line arguments, passed as a list',
		},
	}

=head4 Output

	{ type => 'integer', min => 0, max => 3 }

=head3 MESSAGES

	+-------------------------------------+-------------------------------+------------------------------+
	| Message                             | Meaning                       | Resolution                   |
	+-------------------------------------+-------------------------------+------------------------------+
	| Unknown option: X (exit 2)          | Getopt::Long did not          | See --help                   |
	|                                     | recognise X                   |                              |
	| Missing database filename (exit 2)  | No database was given, or     | Give exactly one database    |
	|                                     | more than one was             |                              |
	| access2csv: Cannot open log file F: | The log file cannot be        | Use --log elsewhere or       |
	|  E (exit 3)                         | appended to                   | --no-log                     |
	| access2csv: MESSAGE (exit 3)        | Any fatal error from the      | See the exporter's MESSAGES  |
	|                                     | exporter                      |                              |
	+-------------------------------------+-------------------------------+------------------------------+

=head3 FORMAL SPECIFICATION

	┌─ Run ──────────────────────────────────────────────────────
	│ argv? : seq STRING ; status! : 0 ‥ 3
	│ opts : OPTION ⇸ VALUE ; rest : seq STRING
	├────────────────────────────────────────────────────────────
	│ (opts, rest) = getopt(argv?)
	│ helpRequested(opts) ⇒ status! = 0
	│ ¬ parsed(argv?) ∨ #rest ≠ 1 ⇒ status! = 2
	│ parsed(argv?) ∧ #rest = 1 ⇒
	│   (fatal(Exporter.Run(head rest)) ⇒ status! = 3) ∧
	│   (¬ fatal(Exporter.Run(head rest)) ⇒
	│        status! = Exporter.Run(head rest).status!)
	└────────────────────────────────────────────────────────────

=head3 PSEUDOCODE

	opts := DEFAULTS
	parse argv into opts; on error print usage and return 2
	if --help or --man: print documentation and return 0
	if not exactly one argument remains: print usage and return 2
	try:
		open the log unless --no-log
		status := Exporter(opts).run(database)
	on error:
		print "access2csv: <message>" to STDERR; status := 3
	return status

=cut

sub run {
	my ($class, @argv) = @_;

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
	return $class->_usage($EXIT_USAGE, $POD_SYNOPSIS, $class->i18n('missing_database')) if @{$argv} != 1;
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

	return unless defined($opt->{log}) && length($opt->{log});

	# Log::Abstraction silently ignores an unwritable file, which would lose
	# the log without telling anyone, so prove that we can append first
	my $file = $opt->{log};
	eval {
		open my $fh, '>>', $file;
		close $fh;
		1;
	} or $class->_croak_i18n('log_open_failed', { params => [$file, (ref($@) && $@->can('errno')) ? $@->errno() : "$!"] });

	return Log::Abstraction->new(
		logger => $file,
		level  => $opt->{verbose} ? $LOG_LEVEL_VERBOSE : $LOG_LEVEL,
	);
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
	my $text = defined($error) && length("$error") ? "$error" : 'Unknown error';
	$text =~ s/ at \S+ line \d+\.?\n?\z// unless $verbose;
	chomp $text;

	print STDERR $class->i18n('fatal', { params => [$text] }), "\n";
	return $EXIT_FATAL;
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * The heavy lifting is done by external mdbtools programs, so their
bugs and their CSV dialect (quoting, date formats, binary columns) are
inherited.  A pure-Perl or DBI-based reader would remove the dependency,
but no maintained CPAN module reads C<.accdb> files.

=item * Messages from L<Getopt::Long>, L<Params::Validate::Strict> and
L<autodie> are not translated.

=item * The log goes to F<access2csv.log> in the current directory by
default, which may surprise users; use B<--log> or B<--no-log>.

=item * Settings are taken from the command line only.  C<%DEFAULTS> is
laid out so that L<Object::Configure> could supply them from a
configuration file, but that is not wired up.

=back

=head1 SEE ALSO

L<App::Access2CSV::Exporter>, L<App::Access2CSV::I18N>, L<Log::Abstraction>,
L<https://github.com/mdbtools/mdbtools>

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 LICENSE AND COPYRIGHT

This program is released under the same terms as Perl itself.

=cut
