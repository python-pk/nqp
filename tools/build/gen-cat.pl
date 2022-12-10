#!/usr/bin/env perl
# Copyright (C) 2008-2011, The Perl Foundation.

use strict;
use warnings;
use 5.008;

binmode STDOUT, ':utf8';

my ($backend, $stage, @files) = @ARGV;

if ($stage ne "stage1" && $stage ne "stage2") {
    unshift @files, $stage;
    $stage = "asdfgh";
}

print <<"END_HEAD";
# This file automatically generated by $0

END_HEAD


foreach my $file (@files) {
    print "#line 1 NQP::$file\n";
    open(my $fh, "<:utf8",  $file) or die "$file: $!";
    my $in_omit = 0;
    my @conds;
    while (<$fh>) {
        if (/^#\?if\s+(!)?\s*(stage\d)\s*$/) {
            push @conds,$in_omit;
            $in_omit = $in_omit || ($1 && $2 eq $stage || !$1 && $2 ne $stage);
        }
        elsif (/^#\?if\s+(!)?\s*(\w+)\s*$/) {
            push @conds,$in_omit;
            $in_omit = $in_omit || ($1 && $2 eq $backend || !$1 && $2 ne $backend);
        }
        elsif (/^#\?endif\s*$/) {
            $in_omit = pop @conds;
        }
        elsif (!$in_omit) {
            print;
        }
    }
    close $fh;
}

print "\n# vim: set ft=perl6 nomodifiable :\n";
