# NAME

App::Access2CSV - Export the tables of a Microsoft Access database to CSV files

# VERSION

Version 0.001

# SYNOPSIS

        access2csv database.accdb

        access2csv --dry-run --show-counts database.accdb

        access2csv --output-dir exports --table Customers --table Orders database.mdb

        access2csv --encoding utf8-bom --overwrite --no-log database.accdb

# DESCRIPTION

`access2csv` writes one CSV file per user table of an Access
(`.mdb` / `.accdb`) database, using the mdbtools programs
`mdb-tables` and `mdb-export`, which must be in your `PATH`.
`mdb-count` is also used if you ask for row counts.

Access's own system tables (`MSys*`, `USys*` and `~*`) are skipped.
Each file is named after its table, with characters that are illegal in
file names replaced by `_`; if two tables would map to the same file
name (ignoring case), later ones get `_2`, `_3`, ... suffixes.

# OPTIONS

- **--output-dir** _DIR_

    Directory to write the CSV files to; created if necessary.  Default: the
    current directory.

- **--table** _NAME_

    Export only this table.  May be given more than once.  Names are
    case-sensitive; unknown names produce a warning.

- **--overwrite**

    Replace CSV files that already exist.  Without it, such tables fail.

- **--verbose**

    Log where the mdbtools programs were found, and show file and line
    numbers in fatal error messages.

- **--dry-run**

    List the tables and the files they would be written to, then stop.
    Nothing is created, not even the output directory.

- **--show-counts**

    Show row counts in the dry-run listing and in the log.  Needs
    `mdb-count`.

- **--no-progress**

    Do not print `[n/total] table` progress lines to STDERR.

- **--encoding** _utf8|utf8-bom|cp1252_

    Character encoding of the CSV files.  `utf8-bom` adds a byte order mark,
    which helps Excel recognise UTF-8.  `cp1252` is Windows-1252; a table
    containing a character with no Windows-1252 equivalent fails.
    Default: `utf8`.

- **--log** _FILE_

    Append a log to _FILE_.  Default: `access2csv.log` in the current
    directory.

- **--no-log**

    Do not write a log file.

- **--help**

    Print the synopsis and options, then exit.

- **--man**

    Print the full manual, then exit.

# EXIT STATUS

        0  every selected table was exported (or --dry-run / --help / --man)
        1  at least one table could not be exported
        2  the command line was invalid
        3  a fatal error stopped the export before it began, e.g. the database
           is missing or mdbtools is not installed

# METHODS

## run

### Purpose

The whole of the `access2csv` program: parse the command line, set up
logging and run an [App::Access2CSV::Exporter](https://metacpan.org/pod/App%3A%3AAccess2CSV%3A%3AExporter).

### Arguments

The command-line arguments, as a list (normally `@ARGV`).  The list is
copied, so the caller's array is not changed.

### Returns

The exit status described in ["EXIT STATUS"](#exit-status).  `run` never calls
`exit` itself, which makes it easy to test.

### Side Effects

Everything the exporter does (see ["run" in App::Access2CSV::Exporter](https://metacpan.org/pod/App%3A%3AAccess2CSV%3A%3AExporter#run)), plus:
prints help or usage text, prints fatal errors to STDERR and appends to
the log file.

### Usage

        exit App::Access2CSV->run(@ARGV);

### EXAMPLE

        use App::Access2CSV;

        # Export to ./out without a log file, and act on the result
        my $status = App::Access2CSV->run('--output-dir', 'out', '--no-log', 'shop.accdb');
        if($status == 1) {
                print "Some tables could not be exported\n";
        }

### API SPECIFICATION

#### Input

        {
                argv => {
                        type     => 'arrayref',
                        optional => 1,
                        element_type => 'string',
                        description  => 'Command-line arguments, passed as a list',
                },
        }

#### Output

        { type => 'integer', min => 0, max => 3 }

### MESSAGES

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

### FORMAL SPECIFICATION

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

### PSEUDOCODE

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

# LIMITATIONS

- The heavy lifting is done by external mdbtools programs, so their
bugs and their CSV dialect (quoting, date formats, binary columns) are
inherited.  A pure-Perl or DBI-based reader would remove the dependency,
but no maintained CPAN module reads `.accdb` files.
- Messages from [Getopt::Long](https://metacpan.org/pod/Getopt%3A%3ALong), [Params::Validate::Strict](https://metacpan.org/pod/Params%3A%3AValidate%3A%3AStrict) and
[autodie](https://metacpan.org/pod/autodie) are not translated.
- The log goes to `access2csv.log` in the current directory by
default, which may surprise users; use **--log** or **--no-log**.
- Settings are taken from the command line only.  `%DEFAULTS` is
laid out so that [Object::Configure](https://metacpan.org/pod/Object%3A%3AConfigure) could supply them from a
configuration file, but that is not wired up.

# SEE ALSO

[App::Access2CSV::Exporter](https://metacpan.org/pod/App%3A%3AAccess2CSV%3A%3AExporter), [App::Access2CSV::I18N](https://metacpan.org/pod/App%3A%3AAccess2CSV%3A%3AI18N), [Log::Abstraction](https://metacpan.org/pod/Log%3A%3AAbstraction),
[https://github.com/mdbtools/mdbtools](https://github.com/mdbtools/mdbtools)

# AUTHOR

Nigel Horne, `<njh at nigelhorne.com>`

# LICENSE AND COPYRIGHT

This program is released under the same terms as Perl itself.
