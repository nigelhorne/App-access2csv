package App::Access2CSV::I18N;

use strict;
use warnings;
use autodie qw(:all);

# Sub::Private must be switched to enforce mode before it is loaded,
# otherwise it falls back to namespace mode, which breaks OO dispatch
BEGIN { $Sub::Private::config{mode} = 'enforce' }

use Carp qw(carp confess croak);
use Params::Get qw(get_params);
use Params::Validate::Strict qw(validate_strict);
use Readonly;
use Return::Set qw(set_return);
use Sub::Private;
use Sub::Protected;

our $VERSION = '0.001';

# The wrappers installed by Sub::Private/Sub::Protected add stack frames;
# listing them here stops Carp from blaming the wrapper for our errors
our @CARP_NOT = qw(Sub::Private Sub::Protected);

# Catalog used when no better match for the user's locale exists
Readonly::Scalar my $DEFAULT_LANGUAGE => 'en';

# Locale values that mean "no preference" rather than a real language
Readonly::Hash my %NEUTRAL_LOCALES => (C => 1, POSIX => 1);

# Environment variables consulted, most specific first (GNU gettext order)
Readonly::Array my @LOCALE_VARIABLES => qw(LANGUAGE LC_ALL LC_MESSAGES LANG);

# Plural category used when a language has no rule of its own
Readonly::Scalar my $PLURAL_OTHER => 'other';

# CLDR-style plural rules.  Each returns the category name for a count.
# Only languages whose rule differs from English need an entry here.
Readonly::Hash my %PLURAL_RULES => (
	en => sub { $_[0] == 1 ? 'one' : 'other' },
	de => sub { $_[0] == 1 ? 'one' : 'other' },
	fr => sub { ($_[0] == 0 || $_[0] == 1) ? 'one' : 'other' },
	ja => sub { 'other' },
	ko => sub { 'other' },
	zh => sub { 'other' },
);

# Message catalog: language => key => template.
# A template is either a sprintf() format, or a hashref whose keys are
# contexts (for example 'male'/'female') and/or plural categories
# ('zero', 'one', 'two', 'few', 'many', 'other').
# It is a package variable, not Readonly, so that applications and
# Object::Configure style configuration can add languages or override text.
our %MESSAGES = (
	en => {
		column_output      => 'OUTPUT FILE',
		column_rows        => 'ROWS',
		column_table       => 'TABLE',
		database_not_file  => 'Database %s is not a regular file',
		database_not_found => 'Cannot read database %s: %s',
		database_unreadable => 'Database %s is not readable',
		dry_run_title      => 'DRY RUN',
		export_failed      => 'FAILED: %s: %s',
		exported           => 'Exported %s => %s',
		exported_rows      => {
			one   => 'Exported %s => %s (%d row)',
			other => 'Exported %s => %s (%d rows)',
		},
		fatal              => 'access2csv: %s',
		invalid_utf8       => 'Table %s, line %d: output of mdb-export is not valid UTF-8',
		log_open_failed    => 'Cannot open log file %s: %s',
		missing_database   => 'Missing database filename',
		mkdir_failed       => 'Cannot create output directory %s: %s',
		no_row_counter     => 'mdb-count not found in PATH; row counts are unavailable',
		output_exists      => 'Output file already exists: %s (use --overwrite to replace it)',
		program_failed     => '%s failed with exit status %d: %s',
		program_found      => 'Found %s at %s',
		program_missing    => 'Required program not found in PATH: %s',
		program_signalled  => '%s was killed by signal %d',
		progress           => '[%d/%d] %s',
		summary            => {
			one   => 'Processed %d table, %d failed',
			other => 'Processed %d tables, %d failed',
		},
		unknown_message    => 'Unknown message key: %s',
		unknown_tables     => {
			one   => 'Table not found in database: %s',
			other => 'Tables not found in database: %s',
		},
		unmappable         => 'Table %s, line %d: cannot be represented in %s',
		write_failed       => 'Cannot write %s: %s',
	},
);

=encoding utf8

=head1 NAME

App::Access2CSV::I18N - Message catalog and localised error reporting for App::Access2CSV

=head1 VERSION

Version 0.001

=head1 SYNOPSIS

	package My::Class;
	use parent 'App::Access2CSV::I18N';

	sub greet {
		my $self = shift;
		print $self->i18n('progress', { params => [1, 3, 'Customers'] }), "\n";
	}

=head1 DESCRIPTION

A small base class that turns message keys into user-facing text.
Every message that App::Access2CSV prints, logs or throws goes through
L</i18n>, so the tool can be translated by adding a language to
C<%App::Access2CSV::I18N::MESSAGES>.

Subclasses also inherit two protected helpers, C<_croak_i18n> and
C<_carp_i18n>, which throw or warn with a localised message via L<Carp>.

=head1 METHODS

=head2 i18n

=head3 Purpose

Look up a message template by key in the catalog for the current language,
choose the right context and plural form, then fill in its C<sprintf>
placeholders.

=head3 Arguments

=over 4

=item C<key> (string, required)

The message key, for example C<'output_exists'>.

=item C<args> (hashref, optional)

=over 4

=item C<params> - arrayref of values passed to C<sprintf>, in order.

=item C<count> - integer used to choose the plural form.

=item C<context> - string used to choose a context-specific form,
for example C<'male'> or C<'female'>.

=back

=back

May be called as a class method or an object method.
When called on an object whose C<language> attribute is set, that language
is used; otherwise the language is taken from the environment
(C<LANGUAGE>, C<LC_ALL>, C<LC_MESSAGES>, C<LANG>, in that order).

=head3 Returns

The formatted message as a string, without a trailing newline.

=head3 Side Effects

None, apart from C<confess> on an unknown key.

=head3 Usage

	my $text = $self->i18n('summary', { params => [3, 0], count => 3 });

=head3 EXAMPLE

	# "Output file already exists: out/Orders.csv (use --overwrite ...)"
	my $msg = App::Access2CSV::I18N->i18n(
		'output_exists',
		{ params => ['out/Orders.csv'] },
	);

	# Plural forms: "Processed 1 table, 0 failed" / "Processed 2 tables, 0 failed"
	print $obj->i18n('summary', { params => [$n, 0], count => $n }), "\n";

	# Adding a translation at run time
	$App::Access2CSV::I18N::MESSAGES{de}{missing_database} =
		'Name der Datenbankdatei fehlt';

=head3 API SPECIFICATION

=head4 Input

	{
		key  => { type => 'string', min => 1 },
		args => {
			type     => 'hashref',
			optional => 1,
			schema   => {
				params  => { type => 'arrayref', optional => 1 },
				count   => { type => 'integer', optional => 1, min => 0 },
				context => { type => 'string', optional => 1 },
			},
		},
	}

=head4 Output

	{ type => 'string' }

=head3 MESSAGES

	+-----------------------------+-------------------------------+---------------------------------+
	| Message                     | Meaning                       | Resolution                      |
	+-----------------------------+-------------------------------+---------------------------------+
	| Unknown message key: KEY    | KEY is not in the default     | Programming error: add KEY to   |
	|  (fatal, via confess)       | (en) catalog                  | %MESSAGES{en}                   |
	| Params::Validate::Strict    | key or args has the wrong     | Pass a key string and an        |
	|  errors (fatal)             | type                          | optional hashref                |
	+-----------------------------+-------------------------------+---------------------------------+

=head3 FORMAL SPECIFICATION

	┌─ I18n ─────────────────────────────────────────────────────
	│ Catalog : LANG ⇸ (KEY ⇸ TEMPLATE)
	│ key? : KEY ; params? : seq VALUE ; count? : ℕ ; context? : CTX
	│ lang : LANG ; msg! : seq CHAR
	├────────────────────────────────────────────────────────────
	│ key? ∈ dom Catalog(en)
	│ lang = (if key? ∈ dom Catalog(userLang) then userLang else en)
	│ t₀ = Catalog(lang)(key?)
	│ t₁ = (if context? ∈ dom t₀ then t₀(context?) else t₀)
	│ t₂ = (if t₁ ∈ STRING then t₁
	│        else if plural(lang, count?) ∈ dom t₁
	│             then t₁(plural(lang, count?)) else t₁(other))
	│ msg! = sprintf(t₂, params?)
	└────────────────────────────────────────────────────────────

=head3 PSEUDOCODE

	validate key and args
	lang  := object language, or language from the environment
	entry := catalog[lang][key], else catalog[en][key], else confess
	if entry is a hash and has args.context: entry := entry[context]
	if entry is still a hash: entry := entry[plural_category(lang, count)]
	                          (falling back to entry['other'])
	return sprintf(entry, params)

=cut

sub i18n {
	my $self = shift;

	# Accept both i18n('key', {...}) and i18n({ key => ..., args => {...} })
	# Undefined values are dropped so that validation reports them as missing
	my $in = (ref($_[0]) eq 'HASH') ? { %{ $_[0] } } : { key => $_[0], args => $_[1] };
	delete @{$in}{ grep { !defined $in->{$_} } keys %{$in} };

	my $params = validate_strict(
		schema => {
			key  => { type => 'string', min => 1 },
			args => { type => 'hashref', optional => 1 },
		},
		input => $in,
	);
	my $args = $params->{args} || {};

	# Resolve the template in the user's language, falling back to English
	my $lang = $self->_language();
	my $entry = $self->_lookup($lang, $params->{key});

	# Narrow a structured template down to a single sprintf() format
	if(ref($entry) eq 'HASH' && defined($args->{context}) && exists($entry->{$args->{context}})) {
		$entry = $entry->{$args->{context}};
	}
	if(ref($entry) eq 'HASH') {
		my $category = _plural_category($lang, $args->{count});
		$entry = exists($entry->{$category}) ? $entry->{$category} : $entry->{$PLURAL_OTHER};
	}

	# A literal message with no placeholders is returned untouched, which
	# protects any '%' characters it contains from sprintf()
	my @values = @{ $args->{params} || [] };
	my $text = @values ? sprintf($entry, @values) : $entry;

	return set_return($text, { type => 'string' });
}

# _croak_i18n
# Purpose:        Throw a localised exception from the caller's point of view.
# Entry Criteria: $key is a catalog key; $args is an optional i18n() hashref.
# Exit Status:    Never returns; always croaks.
# Side Effects:   Unwinds the stack with a Carp exception.
sub _croak_i18n :Protected {
	my ($self, $key, $args) = @_;

	croak($self->i18n($key, $args));
}

# _carp_i18n
# Purpose:        Emit a localised warning from the caller's point of view.
# Entry Criteria: $key is a catalog key; $args is an optional i18n() hashref.
# Exit Status:    Returns $self for chaining.
# Side Effects:   Writes a warning to STDERR (or $SIG{__WARN__}).
sub _carp_i18n :Protected {
	my ($self, $key, $args) = @_;

	carp($self->i18n($key, $args));
	return $self;
}

# _language
# Purpose:        Work out which catalog language to use.
# Entry Criteria: $self is a class name or an object (optionally with {language}).
# Exit Status:    Returns a lower-case language code, e.g. 'en' or 'de'.
# Side Effects:   None; reads %ENV only.
sub _language :Private {
	my $self = shift;

	# An explicit per-object choice beats anything in the environment
	my $wanted = (ref($self) && $self->{language}) ? $self->{language} : undef;

	# Otherwise take the first meaningful locale variable; LANGUAGE may be
	# a colon-separated preference list, so only its first entry is used
	foreach my $var (@LOCALE_VARIABLES) {
		last if defined $wanted;
		my $value = $ENV{$var};
		next unless defined($value) && length($value);
		($value) = split /:/, $value;
		next if !defined($value) || $NEUTRAL_LOCALES{$value};
		$wanted = $value;
	}

	# "de_DE.UTF-8@euro" -> "de"; anything unparseable means English
	my ($code) = (defined($wanted) ? $wanted : '') =~ /\A([A-Za-z]{2,3})(?:[_\-.@]|\z)/;
	return (defined($code) && exists($MESSAGES{lc $code})) ? lc($code) : $DEFAULT_LANGUAGE;
}

# _lookup
# Purpose:        Fetch the raw template for $key in $lang.
# Entry Criteria: $lang is a catalog language; $key is a non-empty string.
# Exit Status:    Returns a string or hashref template.
# Side Effects:   confess()es if $key is missing from the default catalog,
#                 because that can only be a programming error.
sub _lookup :Private {
	my ($self, $lang, $key) = @_;

	# A partial translation silently falls back to English per key
	foreach my $catalog ($MESSAGES{$lang}, $MESSAGES{$DEFAULT_LANGUAGE}) {
		return $catalog->{$key} if $catalog && exists($catalog->{$key});
	}

	# Build the message directly from the English catalog, since calling
	# i18n() here could recurse forever if 'unknown_message' were missing
	confess(sprintf($MESSAGES{$DEFAULT_LANGUAGE}{unknown_message} || 'Unknown message key: %s', $key));
}

# _plural_category
# Purpose:        Map a count to a CLDR plural category for a language.
# Entry Criteria: $lang is a language code; $count is a non-negative
#                 integer or undef (undef means "no plural choice").
# Exit Status:    Returns a category name such as 'one' or 'other'.
# Side Effects:   None.  A plain function, not a method.
sub _plural_category :Private {
	my ($lang, $count) = @_;

	my $rule = $PLURAL_RULES{$lang} || $PLURAL_RULES{$DEFAULT_LANGUAGE};
	return defined($count) ? $rule->($count) : $PLURAL_OTHER;
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * Only an English catalog ships with the distribution.
Other languages fall back to English key by key.

=item * Plural rules are provided for a handful of languages only;
unknown languages use the English rule.

=item * Error messages raised by third-party modules (for example
L<Params::Validate::Strict>, L<autodie>) are not translated.

=item * Access control from L<Sub::Private> and L<Sub::Protected> is
applied at C<CHECK> time.  If this module is first loaded at run time
(C<require> after compilation has finished), Perl warns
"Too late to run CHECK block" and the private and protected helpers
are B<not> protected.

=back

=head1 AUTHOR

Nigel Horne, C<< <nigel.horne at gmail.com> >>

=head1 LICENSE AND COPYRIGHT

This program is released under the same terms as Perl itself.

=cut
