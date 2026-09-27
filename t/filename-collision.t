#!perl

# White-box tests for App::Access2CSV::Exporter::_csv_filename, which is
# protected, so access checks are bypassed explicitly

use strict;
use warnings;

use Test::Most;

use App::Access2CSV::Exporter;

$Sub::Private::BYPASS = 1;
$Sub::Protected::BYPASS = 1;

subtest 'unsafe characters become underscores and names stay unique' => sub {
	my $e = App::Access2CSV::Exporter->new();

	is($e->_csv_filename('Customer/Orders'), 'Customer_Orders.csv', 'slash replaced');
	is($e->_csv_filename('Customer:Orders'), 'Customer_Orders_2.csv', 'collision gets _2');
	is($e->_csv_filename('Customer?Orders'), 'Customer_Orders_3.csv', 'next collision gets _3');
};

subtest 'a table literally called X_2 does not overwrite a suffixed name' => sub {
	my $e = App::Access2CSV::Exporter->new();

	is($e->_csv_filename('A/B'), 'A_B.csv');
	is($e->_csv_filename('A:B'), 'A_B_2.csv');
	is($e->_csv_filename('A_B_2'), 'A_B_2_2.csv', 'real "A_B_2" table does not clash with A_B_2.csv');
};

subtest 'collisions are detected case-insensitively' => sub {
	my $e = App::Access2CSV::Exporter->new();

	is($e->_csv_filename('Orders'), 'Orders.csv');
	is($e->_csv_filename('ORDERS'), 'ORDERS_2.csv', 'differs only by case');
};

subtest 'awkward names' => sub {
	my $e = App::Access2CSV::Exporter->new();

	is($e->_csv_filename(''), 'unnamed.csv', 'empty name');
	is($e->_csv_filename('   '), 'unnamed_2.csv', 'whitespace only');
	is($e->_csv_filename('  Padded  '), 'Padded.csv', 'whitespace trimmed');
	is($e->_csv_filename('Trailing.'), 'Trailing.csv', 'trailing dot dropped');
	is($e->_csv_filename('.hidden'), '_hidden.csv', 'no hidden files');
	is($e->_csv_filename('CON'), '_CON.csv', 'Windows device name');
	is($e->_csv_filename('lpt1'), '_lpt1.csv', 'device names are case-insensitive');
	is($e->_csv_filename("Tab\tNew\nLine"), 'Tab_New_Line.csv', 'control characters');
	is($e->_csv_filename(undef), 'unnamed_3.csv', 'undef treated as empty');
};

subtest 'unicode names are kept' => sub {
	my $e = App::Access2CSV::Exporter->new();

	is($e->_csv_filename("Caf\x{e9}"), "Caf\x{e9}.csv", 'non-ASCII characters are not mangled');
};

done_testing();
