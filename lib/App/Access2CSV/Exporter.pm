package App::Access2CSV::Exporter;

use strict;
use warnings;

use autodie;
use File::Path qw(make_path);
use File::Spec;
use IPC::Run3 qw(run3);

sub new {
    my ($class, %arg) = @_;

    $arg{used_names} ||= {};

    return bless \%arg, $class;
}

sub run {
    my ($self, $database) = @_;

    die "Database not found: $database\n"
        unless -f $database;

    $self->_verify_dependencies();

    make_path($self->{output_dir})
        unless -d $self->{output_dir};

    my @tables = $self->_get_tables($database);

    if ($self->{tables}) {

        my %wanted =
            map { $_ => 1 }
            @{ $self->{tables} };

        @tables =
            grep { $wanted{$_} } @tables;
    }

    if ($self->{dry_run}) {

        $self->_dry_run(
            $database,
            @tables,
        );

        return 0;
    }

    my $total   = scalar @tables;
    my $current = 0;
    my $failed  = 0;

    foreach my $table (@tables) {

        ++$current;

        if ($self->{progress}) {

            printf(
                "[%d/%d] %s\n",
                $current,
                $total,
                $table,
            );
        }

        eval {

            $self->_export_table(
                $database,
                $table,
            );

            1;
        }
        or do {

            ++$failed;

            my $err =
                $@ || 'Unknown error';

            warn $err;

            $self->{logger}->log(
                "FAILED: $table : $err"
            );
        };
    }

    return $failed ? 1 : 0;
}

sub _verify_dependencies {

    my ($self) = @_;

    foreach my $cmd (
        qw(
            mdb-tables
            mdb-export
        )
    ) {

        my ($out, $err);

        run3(
            [ $cmd, '--help' ],
            undef,
            \$out,
            \$err,
        );
    }

    return;
}

sub _get_tables {

    my (
        $self,
        $database
    ) = @_;

    my ($stdout, $stderr);

    run3(
        [
            'mdb-tables',
            '-1',
            $database,
        ],
        undef,
        \$stdout,
        \$stderr,
    );

    die $stderr if $?;

    my @tables =
        split /\n/, $stdout;

    @tables =
        grep { length }
        grep { !$self->_is_system_table($_) }
        @tables;

    return sort @tables;
}

sub _is_system_table {

    my (
        $self,
        $table
    ) = @_;

    return 1 if $table =~ /^MSys/i;
    return 1 if $table =~ /^USys/i;
    return 1 if $table =~ /^~/;

    return 0;
}

sub _export_table {

    my (
        $self,
        $database,
        $table
    ) = @_;

    my ($stdout, $stderr);

    run3(
        [
            'mdb-export',
            $database,
            $table,
        ],
        undef,
        \$stdout,
        \$stderr,
    );

    die $stderr if $?;

    my $outfile =
        File::Spec->catfile(
            $self->{output_dir},
            $self->_csv_filename(
                $table
            ),
        );

    if (
        -e $outfile
        &&
        !$self->{overwrite}
    ) {

        die "File exists: $outfile\n";
    }

    open my $fh,
        '>:raw',
        $outfile;

    if (
        $self->{encoding}
        eq 'utf8-bom'
    ) {

        print {$fh}
            "\xEF\xBB\xBF";
    }

    print {$fh} $stdout;

    close $fh;

    $self->{logger}->log(
        "Exported $table => $outfile"
    );

    return;
}

sub _csv_filename {

    my (
        $self,
        $table
    ) = @_;

    my $name = $table;

    $name =~ s/[<>:"\/\\|?*]/_/g;
    $name =~ s/\s+$//;
    $name =~ s/^\s+//;

    $name = 'unnamed'
        unless length $name;

    my $file = "$name.csv";

    my $used =
        $self->{used_names};

    if (
        exists $used->{$file}
    ) {

        my $n = ++$used->{$file};

        $file =
            sprintf(
                '%s_%d.csv',
                $name,
                $n,
            );
    }
    else {

        $used->{$file} = 1;
    }

    return $file;
}

sub _dry_run {

    my (
        $self,
        $database,
        @tables
    ) = @_;

    print "\n";
    print "DRY RUN\n";
    print "=======\n\n";

    foreach my $table (@tables) {

        my $file =
            $self->_csv_filename(
                $table
            );

        print "$table => $file\n";
    }

    print "\n";

    return;
}

1;
