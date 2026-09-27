package App::Access2CSV::Logger;

use strict;
use warnings;

use autodie;

sub new {
    my ($class, %arg) = @_;

    open my $fh,
        '>>:encoding(UTF-8)',
        $arg{file};

    my $self = {
        fh => $fh,
    };

    return bless $self, $class;
}

sub log {
    my ($self, $msg) = @_;

    my $stamp = scalar localtime;

    print { $self->{fh} }
        "[$stamp] $msg\n";

    return;
}

1;
