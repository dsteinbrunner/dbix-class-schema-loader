package DBIx::Class::Schema::Loader::SQLite;

use strict;
use base qw/DBIx::Class::Schema::Loader::Generic/;
use Text::Balanced qw( extract_bracketed );
use Carp;

=head1 NAME

DBIx::Class::Schema::Loader::SQLite - DBIx::Class::Schema::Loader SQLite Implementation.

=head1 SYNOPSIS

  use DBIx::Class::Schema::Loader;

  # $loader is a DBIx::Class::Schema::Loader::SQLite
  my $loader = DBIx::Class::Schema::Loader->new(
    dsn       => "dbi:SQLite:dbname=/path/to/dbfile",
  );

=head1 DESCRIPTION

See L<DBIx::Class::Schema::Loader>.

=cut

sub _loader_db_classes {
    return qw/DBIx::Class::PK::Auto::SQLite/;
}

# XXX this really needs a re-factor
sub _loader_relationships {
    my $class = shift;
    foreach my $table ( $class->tables ) {

        my $dbh = $class->storage->dbh;
        my $sth = $dbh->prepare(<<"");
SELECT sql FROM sqlite_master WHERE tbl_name = ?

        $sth->execute($table);
        my ($sql) = $sth->fetchrow_array;
        $sth->finish;

        # Cut "CREATE TABLE ( )" blabla...
        $sql =~ /^[\w\s]+\((.*)\)$/si;
        my $cols = $1;

        # strip single-line comments
        $cols =~ s/\-\-.*\n/\n/g;

        # temporarily replace any commas inside parens,
        # so we don't incorrectly split on them below
        my $cols_no_bracketed_commas = $cols;
        while ( my $extracted =
            ( extract_bracketed( $cols, "()", "[^(]*" ) )[0] )
        {
            my $replacement = $extracted;
            $replacement              =~ s/,/--comma--/g;
            $replacement              =~ s/^\(//;
            $replacement              =~ s/\)$//;
            $cols_no_bracketed_commas =~ s/$extracted/$replacement/m;
        }

        # Split column definitions
        for my $col ( split /,/, $cols_no_bracketed_commas ) {

            # put the paren-bracketed commas back, to help
            # find multi-col fks below
            $col =~ s/\-\-comma\-\-/,/g;

            $col =~ s/^\s*FOREIGN\s+KEY\s*//i;

            # Strip punctuations around key and table names
            $col =~ s/[\[\]'"]/ /g;
            $col =~ s/^\s+//gs;

            # Grab reference
            if( $col =~ /^(.*)\s+REFERENCES\s+(\w+)\s*\((.*)\)/i ) {
                chomp $col;

                my ($cols, $f_table, $f_cols) = ($1, $2, $3);

                if($cols =~ /^\(/) { # Table-level
                    $cols =~ s/^\(\s*//;
                    $cols =~ s/\s*\)$//;
                }
                else {               # Inline
                    $cols =~ s/\s+.*$//;
                }

                my @cols = map { s/\s*//g; $_ } split(/\s*,\s*/,$cols);
                my @f_cols = map { s/\s*//g; $_ } split(/\s*,\s*/,$f_cols);

                die "Mismatched column count in rel for $table => $f_table"
                  if @cols != @f_cols;
            
                my $cond = {};
                for(my $i = 0 ; $i < @cols; $i++) {
                    $cond->{$f_cols[$i]} = $cols[$i];
                }

                eval { $class->_loader_make_relations( $table, $f_table, $cond ) };
                warn qq/\# belongs_to_many failed "$@"\n\n/
                  if $@ && $class->_loader_debug;
            }
        }
    }
}

sub _loader_tables {
    my $class = shift;
    my $dbh = $class->storage->dbh;
    my $sth  = $dbh->prepare("SELECT * FROM sqlite_master");
    $sth->execute;
    my @tables;
    while ( my $row = $sth->fetchrow_hashref ) {
        next unless lc( $row->{type} ) eq 'table';
        push @tables, $row->{tbl_name};
    }
    return @tables;
}

sub _loader_table_info {
    my ( $class, $table ) = @_;

    # find all columns.
    my $dbh = $class->storage->dbh;
    my $sth = $dbh->prepare("PRAGMA table_info('$table')");
    $sth->execute();
    my @columns;
    while ( my $row = $sth->fetchrow_hashref ) {
        push @columns, $row->{name};
    }
    $sth->finish;

    # find primary key. so complex ;-(
    $sth = $dbh->prepare(<<'SQL');
SELECT sql FROM sqlite_master WHERE tbl_name = ?
SQL
    $sth->execute($table);
    my ($sql) = $sth->fetchrow_array;
    $sth->finish;
    my ($primary) = $sql =~ m/
    (?:\(|\,) # either a ( to start the definition or a , for next
    \s*       # maybe some whitespace
    (\w+)     # the col name
    [^,]*     # anything but the end or a ',' for next column
    PRIMARY\sKEY/sxi;
    my @pks;

    if ($primary) {
        @pks = ($primary);
    }
    else {
        my ($pks) = $sql =~ m/PRIMARY\s+KEY\s*\(\s*([^)]+)\s*\)/i;
        @pks = split( m/\s*\,\s*/, $pks ) if $pks;
    }
    return ( \@columns, \@pks );
}

=head1 SEE ALSO

L<DBIx::Schema::Class::Loader>

=cut

1;