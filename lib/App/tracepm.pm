package App::tracepm;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any::IfLOG '$log';

use version;

our %SPEC;

our $tablespec = {
    fields => {
        module  => {schema=>'str*' , pos=>0},
        version => {schema=>'str*' , pos=>1},
        require => {schema=>'str*' , pos=>2},
        by      => {schema=>'str*' , pos=>3},
        seq     => {schema=>'int*' , pos=>4},
        is_xs   => {schema=>'bool' , pos=>5},
        is_core => {schema=>'bool*', pos=>6},
    },
    pk => 'module',
};

$SPEC{tracepm} = {
    v => 1.1,
    summary => 'Trace dependencies of your Perl script',
    args => {
        script => {
            summary => 'Path to script file (script to be packed)',
            schema => ['str*'],
            pos => 0,
            tags => ['category:input'],
        },
        eval => {
            summary => 'Specify script from command-line instead',
            schema  => 'str*',
            cmdline_aliases => {e=>{}},
            tags => ['category:input'],
        },
        method => {
            summary => 'Tracing method to use',
            schema => ['str*',
                       in=>[qw/
                                  fatpacker
                                  require
                                  prereqscanner
                                  prereqscanner_lite
                                  prereqscanner_recurse
                                  prereqscanner_lite_recurse
                              /]],
            default => 'fatpacker',
            description => <<'_',

There are several tracing methods that can be used:

* `fatpacker` (the default): This method uses the same method that `fatpacker
  trace` uses, which is running the script using `perl -c` then collect the
  populated `%INC`. Only modules loaded during compile time are detected.

* `require`: This method runs your script normally until it exits. At the start
  of program, it replaces `CORE::GLOBAL::require()` with a routine that logs the
  require() argument to the log file. Modules loaded during runtime is also
  logged by this method. But some modules might not work, specifically modules
  that also overrides require() (there should be only a handful of modules that
  do this though).

* `prereqscanner`: This method does not run your Perl program, but statically
  analyze it using `Perl::PrereqScanner`. Since it uses `PPI`, it can be rather
  slow.

* `prereqscanner_recurse`: Like `prereqscanner`, but will recurse into all
  non-core modules until they are exhausted. Modules that are not found will be
  skipped. It is recommended to use the various `recurse_exclude_*` options
  options to limit recursion.

* `prereqscanner_lite`: This method is like the `prereqscanner` method, but
  instead of `Perl::PrereqScanner` it uses `Perl::PrereqScanner::Lite`. The
  latter does not use `PPI` but use `Compiler::Lexer` which is significantly
  faster.

* `prereqscanner_lite_recurse`: Like `prereqscanner_lite`, but recurses.

_
        },
        cache_prereqscanner => {
            summary => "Whether cache Perl::PrereqScanner{,::Lite} result",
            schema => ['bool' => default=>0],
        },
        recurse_exclude => {
            summary => 'When recursing, exclude some modules',
            schema => ['array*' => of => 'str*'],
        },
        recurse_exclude_pattern => {
            summary => 'When recursing, exclude some module patterns',
            schema => ['array*' => of => 'str*'], # XXX array of re
        },
        recurse_exclude_xs => {
            summary => 'When recursing, exclude XS modules',
            schema => ['bool'],
        },
        recurse_exclude_core => {
            summary => 'When recursing, exclude core modules',
            schema => ['bool'],
        },
        trap_script_output => {
            # XXX relevant only when method=trace or method=require
            summary => 'Trap script output so it does not interfere '.
                'with trace result',
            schema => ['bool', is=>1],
        },
        args => {
            summary => 'Script arguments',
            schema => ['array*' => of => 'str*'],
            req => 0,
            pos => 1,
            greedy => 1,
        },
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
    require File::Temp;

    my %args = @_;

    my $script = $args{script};
    unless (defined $script) {
        my $eval = $args{eval};
        defined($eval) or die "Please specify input script or --eval (-e)\n";
        my ($fh, $filename) = File::Temp::tempfile();
        print $fh $eval;
        $script = $filename;
    }

    my $method = $args{method};
    my $plver = version->parse($args{perl_version} // $^V);

    my $add_fields_and_filter_1 = sub {
        my $r = shift;
        if ($args{detail} || defined($args{core})) {
            require Module::CoreList::More;
            my $is_core = Module::CoreList::More->is_still_core(
                $r->{module}, undef, $plver);
            return 0 if defined($args{core}) && ($args{core} xor $is_core);
            $r->{is_core} = $is_core;
        }

        if ($args{detail} || defined($args{xs})) {
            require Module::XSOrPP;
            my $is_xs = Module::XSOrPP::is_xs($r->{module});
            return 0 if defined($args{xs}) && (
                !defined($is_xs) || ($args{xs} xor $is_xs));
            $r->{is_xs} = $is_xs;
        }
        1;
    };

    my @res;
    if ($method =~ /\A(fatpacker|require)\z/) {

        my ($outfh, $outf) = File::Temp::tempfile();

        my $routine;
        if ($method eq 'fatpacker') {
            $routine = sub {
                require App::FatPacker;
                my $fp = App::FatPacker->new;
                $fp->trace(
                    output => ">>$outf",
                    use    => $args{use},
                    args   => [$script, @{$args{args} // []}],
                );
            };
        } else {
            # 'require' method
            $routine = sub {
                system($^X,
                       "-MApp::tracepm::Tracer=$outf",
                       (map {"-M$_"} @{$args{use} // []}),
                       $script, @{$args{args} // []},
                   );
            };
        }

        if ($args{trap_script_output}) {
            require Capture::Tiny;
            Capture::Tiny::capture_merged($routine);
        } else {
            $routine->();
        }

        open my($fh), "<", $outf
            or die "Can't open trace output: $!";

        my $i = 0;
        while (<$fh>) {
            chomp;
            $log->trace("got line: $_");

            my $r = {};
            $i++;
            $r->{seq} = $i if $method eq 'require';

            if (/(.+)\t(.+)/) {
                $r->{require} = $1;
                $r->{by} = $2;
            } else {
                $r->{require} = $_;
            }

            unless ($r->{require} =~ /(.+)\.pm\z/) {
                warn "Skipped non-pm entry: $_\n";
                next;
            }
            my $mod = $1; $mod =~ s!/!::!g;
            $r->{module} = $mod;

            next unless $add_fields_and_filter_1->($r);
            push @res, $r;
        }

        unlink $outf;

    } elsif ($method =~ /\A(?:prereqscanner|prereqscanner_lite)(_recurse)?\z/) {

        require CHI;
        require Module::Path::More;

        my @recurse_blacklist = (
            'Module::List', # segfaults on my pc
        );

        my $chi = CHI->new(driver => $args{cache_prereqscanner} ? "File" : "Null");

        my $recurse = $1 ? 1:0;
        my %seen_mods; # for limiting recursion

        my $scanner;
        my $scan;
        $scan = sub {
            my $file = shift;
            $log->infof("Scanning %s ...", $file);
            my $cache_key = "tracepm-$method-$file";
            my $sres = $chi->compute(
                $cache_key, "24h", # XXX cache should check timestamp
                sub { $scanner->scan_file($file) },
            );
            my $reqs = $sres->{requirements};

            my @new; # new modules to check
          MOD:
            for my $mod (keys %$reqs) {
                next if $mod =~ /\A(perl)\z/;
                my $req = $reqs->{$mod};
                my $v = $req->{minimum}{original};
                my $r = {module=>$mod, version=>$v};

              CHECK_RECURSE:
                {
                    last unless $recurse;
                    last MOD if $seen_mods{$mod}++;
                    my $path = Module::Path::More::module_path(module=>$mod);
                    unless ($path) {
                        $log->infof("Skipped recursing to %s: path not found", $mod);
                        last;
                    }
                    if ($mod ~~ @recurse_blacklist) {
                        $log->infof("Skipped recursing to %s: excluded by hard-coded blacklist", $mod);
                        last;
                    }
                    if ($args{recurse_exclude}) {
                        if ($mod ~~ @{ $args{recurse_exclude} }) {
                            $log->infof("Skipped recursing to %s: excluded by list", $mod);
                            last;
                        }
                    }
                    if ($args{recurse_exclude_pattern}) {
                        for (@{ $args{recurse_exclude_pattern} }) {
                            if ($mod =~ /$_/) {
                                $log->infof("Skipped recursing to %s: excluded by pattern %s", $mod, $_);
                                last CHECK_RECURSE;
                            }
                        }
                    }
                    if ($args{recurse_exclude_core}) {
                        require Module::CoreList::More;
                        my $is_core = Module::CoreList::More->is_still_core(
                            $mod, undef, $plver); # XXX use $v?
                        if ($is_core) {
                            $log->infof("Skipped recursing to %s: core module", $mod);
                        }
                    }
                    if ($args{recurse_exclude_xs}) {
                        require Module::XSOrPP;
                        my $is_xs = Module::XSOrPP::is_xs($mod);
                        if ($is_xs) {
                            $log->infof("Skipped recursing to %s: XS module", $mod);
                            last;
                        }
                    }
                    push @new, $path;
                }

                next unless $add_fields_and_filter_1->($r);
                push @res, $r;
            }
            if (@new) {
                $log->debugf("Recursively scanning %s ...", join(", ", @new));
                $scan->($_) for @new;
            }
        };

        my $sres;
        if ($method eq 'prereqscanner') {
            require Perl::PrereqScanner;
            $scanner = Perl::PrereqScanner->new;
        } else {
            # 'prereqscanner_lite' method
            require Perl::PrereqScanner::Lite;
            $scanner = Perl::PrereqScanner::Lite->new;
        }
        $scan->($script);

    } else {

        return [400, "Unknown trace method '$method'"];

    } # if method

    unless ($args{detail}) {
        @res = map {$_->{module}} @res;
    }

    my $ff = $tablespec->{fields};
    my @ff = sort {$ff->{$a}{pos} <=> $ff->{$b}{pos}} keys %$ff;
    [200, "OK", \@res, {"table.fields" => \@ff}];
}

1;
# ABSTRACT:

=for Pod::Coverage ^()$

=head1 SYNOPSIS

This distribution provides command-line utility called L<tracepm>.
