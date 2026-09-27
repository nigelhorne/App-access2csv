use Test::Most;

use App::access2CSV::Exporter;

my $e =
    App::access2CSV::Exporter->new();

is(
    $e->_csv_filename(
        'Customer/Orders'
    ),
    'Customer_Orders.csv'
);

is(
    $e->_csv_filename(
        'Customer:Orders'
    ),
    'Customer_Orders_2.csv'
);

done_testing;
