package App::access2CSV;
 
use strict;
use warnings;
 
use autodie;
use Getopt::Long qw(GetOptionsFromArray);
use Pod::Usage qw(pod2usage);
 
use App::access2CSV::Exporter;
use App::access2CSV::Logger;
 
our $VERSION = '0.001';
 
sub run {
    my ($class, @argv) = @_;
 
    my %opt = (
        output_dir => '.',
        overwrite  => 0,
        verbose    => 0,
        dry_run    => 0,
        show_counts => 0,
        encoding   => 'utf8',
        progress   => 1,
        log        => 'access2CSV.log',
    );
 
    GetOptionsFromArray(
        \@argv,
        'output-dir=s' => \$opt{output_dir},
        'table=s@'     => \$opt{tables},
        'overwrite!'   => \$opt{overwrite},
        'verbose!'     => \$opt{verbose},
        'dry-run!'     => \$opt{dry_run},
        'show-counts!' => \$opt{show_counts},
        'encoding=s'   => \$opt{encoding},
        'progress!'    => \$opt{progress},
        'log=s'        => \$opt{log},
        'help|h'       => sub { pod2usage(1) },
    );
 
    my $database = shift @argv
        or pod2usage("Missing ACCDB filename");
 
    my $logger = App::access2CSV::Logger->new(
        file => $opt{log}
    );
 
    my $exporter = App::access2CSV::Exporter->new(
        %opt,
        logger => $logger,
    );
 
    return $exporter->run($database);
}
 
1;
