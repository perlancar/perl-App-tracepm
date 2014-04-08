package App::tracepm;

use 5.010001;
use strict;
use warnings;
#use experimental 'smartmatch';
use Log::Any '$log';

use App::FatPacker;
use File::Temp qw(tempfile);
use Module::CoreList;
use SHARYANTO::Module::Util qw(is_xs);
use version;

# VERSION

our %SPEC;

our $tablespec = {
    fields => {
        module  => {schema=>'str*' , pos=>0},
        require => {schema=>'str*' , pos=>1},
        seq     => {schema=>'int*' , pos=>2},
        is_xs   => {schema=>'bool' , pos=>3},
        is_core => {schema=>'bool*', pos=>4},
    },
    pk => 'module',
};

$SPEC{tracepm} = {
    v => 1.1,
    args => {
        script => {
            summary => 'Path to script file (script to be packed)',
            schema => ['str*'],
            req => 1,
            pos => 0,
        },
        #args => {
        #    summary => 'Script arguments',
        #    schema => ['array*' => of => 'str*'],
        #    req => 0,
        #    pos => 1,
        #    greedy => 0,
        #},
        perl_version => {
            summary => 'Perl version, defaults to current running version',
            description => <<'_',

This is for determining which module is core (the list differs from version to
version. See Module::CoreList for more details.

_
            schema => ['str*'],
            cmdline_aliases => { V=>{} },
        },
        use => {
            summary => 'Additional modules to "use"',
            schema => ['array*' => of => 'str*'],
            description => <<'_',

This is like running:

    perl -MModule1 -MModule2 script.pl

_
        },
        detail => {
            summary => 'Whether to return records instead of just module names',
            schema => ['bool' => default=>0],
            tags => ['category:field-selection'],
        },
        core => {
            summary => 'Filter only modules that are in core',
            schema  => 'bool',
            tags => ['category:filtering'],
        },
        xs => {
            summary => 'Filter only modules that are XS modules',
            schema  => 'bool',
            tags => ['category:filtering'],
        },
        # fields
    },
    result => {
        table => { spec=>$tablespec },
    },
};
sub tracepm {
    my %args = @_;

    my $plver = version->parse($args{perl_version} // $^V);

    my ($outfh, $outf) = tempfile();

    my $fp = App::FatPacker->new;
    $fp->trace(
        output => ">>$outf",
        use    => $args{use},
        args   => [$args{script}, @{$args{args} // []}],
    );

    open my($fh), "<", $outf
        or die "Can't open fatpacker trace output: $!";

    my @res;
    my $i = 0;
    while (<$fh>) {
        chomp;
        $log->trace("got line: $_");
        $i++;
        my $r = {seq=>$i, require=>$_};

        unless (/(.+)\.pm\z/) {
            warn "Skipped non-pm entry: $_\n";
            next;
        }

        my $mod = $1; $mod =~ s!/!::!g;
        $r->{module} = $mod;

        if ($args{detail} || defined($args{core})) {
            my $is_core = Module::CoreList::is_core($mod, undef, $plver);
            next if defined($args{core}) && ($args{core} xor $is_core);
            $r->{is_core} = $is_core;
        }

        if ($args{detail} || defined($args{xs})) {
            my $is_xs = is_xs($mod);
            next if defined($args{xs}) && (
                !defined($is_xs) || ($args{xs} xor $is_xs));
            $r->{is_xs} = $is_xs;
        }

        push @res, $r;
    }

    unlink $outf;

    unless ($args{detail}) {
        @res = map {$_->{module}} @res;
    }

    my $ff = $tablespec->{fields};
    my @ff = sort {$ff->{$a}{pos} <=> $ff->{$b}{pos}} keys %$ff;
    [200, "OK", \@res, {"table.fields" => \@ff}];
}

1;
# ABSTRACT: Trace dependencies of your Perl script file

=for Pod::Coverage ^()$

=head1 SYNOPSIS

This distribution provides command-line utility called L<tracepm>.

=cut
