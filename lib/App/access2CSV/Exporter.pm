package App::access2CSV::Exporter;

use strict;
use warnings;

use autodie;
use Encode qw(
    encode
    decode
);
use File::Path qw(make_path);
use File::Spec;
use IPC::Run3 qw(run3);
sub new {
    my ($class, %arg) = @_;

    $arg{used_names} = {};

    bless \%arg, $class;
}

sub run {
    my ($self, $database) = @_;

    $self->_verify_dependencies();

    make_path($self->{output_dir})
        unless -d $self->{output_dir};

    my @tables =
        $self->_get_tables($database);

    my $total = scalar @tables;
    my $current = 0;
    my $failed  = 0;

    if ($self->{dry_run}) {

        print "Dry run\n\n";

        foreach my $table (@tables) {

            print "$table\n";
        }

        return 0;
    }

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

            $self->{logger}->log(
                "FAILED $table: $@"
            );
        };
    }

    return $failed ? 1 : 0;
}

sub _verify_dependencies {

    foreach my $cmd (
        qw(
            mdb-tables
            mdb-export
        )
    ) {

        my ($out, $err);

        eval {

            run3(
                [ $cmd, '--help' ],
                undef,
                \$out,
                \$err,
            );

            1;
        }
        or die "$cmd not installed\n";
    }
}

sub _get_tables {

    my ($self, $database) = @_;

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

    my @tables =
        split /\n/, $stdout;

    @tables = grep {
        !$self->_is_system_table($_)
    } @tables;

    return sort @tables;
}

sub _is_system_table {

    my ($self, $table) = @_;

    return 1 if $table =~ /^MSys/i;
    return 1 if $table =~ /^USys/i;
    return 1 if $table =~ /^~/;

    return 0;
}

our %USED_NAMES;

sub _csv_filename {

    my ($self, $table) = @_;

my $used = $self->{used_names};
    my $name = $table;

    $name =~ s/[<>:"\/\\|?*]/_/g;

    my $base = $name;

    my $file = "$base.csv";

    if (exists $USED_NAMES{$file}) {

        my $n = ++$USED_NAMES{$file};

        $file =
            sprintf(
                '%s_%d.csv',
                $base,
                $n
            );
    }
    else {

        $USED_NAMES{$file} = 1;
    }

    return $file;
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

    my $file =
        File::Spec->catfile(
            $self->{output_dir},
            $self->_csv_filename(
                $table
            ),
        );

    open my $fh, '>:raw', $file;

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
        "Exported $table -> $file"
    );
}

1;
