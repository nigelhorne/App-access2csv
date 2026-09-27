use Test::Most;

use App::access2csv::Exporter;

my $e =
    App::access2csv::Exporter->new();

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
