use QRegex;

class NQP::Compiler is HLL::Compiler {
    method optimize($ast, *%adverbs) {
        %adverbs<optimize> eq 'off'
            ?? $ast
            !! NQP::Optimizer.new.optimize($ast, |%adverbs)
    }
}

nqp::bindhllsym('default', 'SysConfig', HLL::SysConfig.new());

# Create and configure compiler object.
my $nqpcomp := NQP::Compiler.new();
$nqpcomp.language('nqp');
$nqpcomp.parsegrammar(NQP::Grammar);
$nqpcomp.parseactions(NQP::Actions);

$nqpcomp.addstage('optimize', :after<ast>);

# Add extra command line options.
my @clo := $nqpcomp.commandline_options();
@clo.push('parsetrace');
@clo.push('setting=s');
@clo.push('setting-path=s');
@clo.push('custom-regex-lib=s');
@clo.push('module-path=s');
@clo.push('no-regex-lib');
@clo.push('stable-sc=s');
@clo.push('optimize=s');
#?if jvm
@clo.push('javaclass=s');
@clo.push('bootstrap');
$nqpcomp.addstage('classname', :after<start>);
#?endif

@clo.push('vmlibs=s');
@clo.push('bootstrap');

#?if js
@clo.push('nyi=s');
#?endif


# XXX FIX ME
sub MAIN(@ARGS) {

#?if jvm
sub MAIN(*@ARGS) {
#?endif
#?if js
sub MAIN(*@ARGS) {
#?endif
    # Enter the compiler.
    $nqpcomp.command_line(@ARGS, :encoding('utf8'));

    # Uncomment below to dump cursor usage logging (also need to uncomment two lines
    # in src/QRegex/Cursor.nqp, in !cursor_start_cur and !cursor_start_all).
    #ParseShared.log_dump();

    # Close event logging
    $nqpcomp.nqpevent();
}
