#!/usr/bin/perl -w
use strict;

print "LOGIN anonymous hogehoge x1\n";
print "%%SETBUOY buoy_foo-99999-999 ";

while ( <> ) { if ( /^([+-])(\d\d\d\d\w\w),T(\d+)/ ) { print "$1$2"; } }

print " 999\n";
print "LOGOUT";
