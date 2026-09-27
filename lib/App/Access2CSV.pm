package App::Access2CSV;

use strict;
use warnings;

use Getopt::Long qw(GetOptionsFromArray);
use Pod::Usage qw(pod2usage);

use App::Access2CSV::Exporter;
use App::Access2CSV::Logger;

our $VERSION = '0.001';

sub run {
    my ($class, @argv) = @_;

    my %opt = (
        output_dir => '.',
        overwrite  => 0,
        verbose    => 0,
        dry_run    => 0,
        show_counts => 0,
        progress   => 1,
        encoding   => 'utf8',
        log        => 'access2csv.log',
    );

    GetOptionsFromArray(
        \@argv,

        'output-dir=s' => \$opt{output_dir},
        'table=s@'     => \$opt{tables},
        'overwrite!'   => \$opt{overwrite},
        'verbose!'     => \$opt{verbose},
        'dry-run!'     => \$opt{dry_run},
        'show-counts!' => \$opt{show_counts},
        'progress!'    => \$opt{progress},
        'encoding=s'   => \$opt{encoding},
        'log=s'        => \$opt{log},

        'help|h' => sub {
            pod2usage(
                -verbose => 1,
                -exitval => 0,
            );
        },

        'man' => sub {
            pod2usage(
                -verbose => 2,
                -exitval => 0,
            );
        },
    );

    my $database = shift @argv;

    pod2usage(
        -message => "Missing ACCDB filename",
        -verbose => 0,
        -exitval => 2,
    ) unless defined $database;

    my $logger = App::Access2CSV::Logger->new(
        file => $opt{log},
    );

    my $exporter = App::Access2CSV::Exporter->new(
        %opt,
        logger => $logger,
    );

    return $exporter->run($database);
}

1;

__END__

=head1 NAME

App::Access2CSV

=head1 SYNOPSIS

    access2csv database.accdb

    access2csv --dry-run database.accdb

    access2csv --output-dir exports database.accdb

=head1 OPTIONS

    --output-dir DIR
    --table NAME
    --overwrite
    --verbose
    --dry-run
    --show-counts
    --progress
    --encoding utf8|utf8-bom|cp1252
    --log FILE
    --help
    --man

=cut
