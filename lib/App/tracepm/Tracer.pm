# we need to run without loading any module
## no critic: TestingAndDebugging::RequireUseStrict
package App::tracepm::Tracer;

# AUTHORITY
# DATE
# DIST
# VERSION

# saving CORE::GLOBAL::require doesn't work
my $orig_require;

sub import {
    my $self = shift;

    # already installed
    return if $orig_require;

    # doesn't mention any file, e.g. in 00-compile.t
    my $file = shift
        or return;

    my $opts = {
        workaround_log4perl => 1,
    };
    if (@_ && ref($_[0]) eq 'HASH') {
        $opts = shift;
    }


    open my($fh), ($ENV{TRACEPM_TRACER_APPEND} ? ">>":">"),
        $file or die "Can't open $file: $!";

    #$orig_require = \&CORE::GLOBAL::require;
    *CORE::GLOBAL::require = sub {
        my ($arg) = @_;
        my $caller = caller;
        if ($INC{$arg}) {
            if ($opts->{workaround_log4perl}) {
                # Log4perl <= 1.43 still does 'eval "require $foo" or ...'
                # instead of 'eval "require $foo; 1" or ...' so running will
                # fail. this workaround makes require() return 1.
                return 1 if $caller =~ /^Log::Log4perl/;
            }
            return 0;
        }
        unless ($arg =~ /\A\d/) { # skip 'require 5.xxx'
            print $fh $arg, "\t", $caller, "\n";
        }

        #$orig_require->($arg);
        CORE::require($arg);
    };
}

1;
# ABSTRACT: Trace module require to file
