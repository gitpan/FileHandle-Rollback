#!/usr/local/bin/perl -w
use strict;
use lib '../../'; # TESTING
use FileHandle::Rollback;
use Fcntl ':flock';
use Test;

BEGIN { plan tests => 12 };


# path for test file
my $path = './test.db';
my $org = '0123456789';
my $orglen = length($org);

reset_file($path, $org);

#------------------------------------------------------
# test: write block
# 
{
	my ($fh, $data);

	# get rollback file handle
	$fh = FileHandle::Rollback->new("+< $path")
		or die "cannot open filehandle: $!";
	
	unless ($fh->flock(LOCK_EX))
		{die "cannot lock filehandle: $!"}


	# binmode: doesn't do anything, but the method should be there
	binmode $fh;
	
	# TEST 0
	# basic read with no modifications
	$fh->seek(0,0);
	$fh->read($data, 40);
	err_comp(0, $data, $org);
	
	
	# go to position 2 (i.e. the third position)
	# and write a couple characters
	$fh->seek(2,0);
	print $fh 'XX';
	
	# TEST 1: read through block
	# starting at the beginning,
	# grab 40 characters (i.e. more than we have)
	$fh->seek(0,0);
	$fh->read($data, 40);
	err_comp(1, $data, '01XX456789');
	
	
	# TEST 2: read from middle of block
	$fh->seek(3,0);
	$fh->read($data, 40);
	err_comp(2, $data, 'X456789');
	
	# TEST 3: read from after block
	$fh->seek(5,0);
	$fh->read($data, 40);
	err_comp(3, $data, '56789');

	# TEST 4: add anothe rblock, then from middle of first
	# block to middle of second
	$fh->seek(7,0);
	print $fh 'XX';
	$fh->seek(3,0);
	$fh->read($data, 5);
	err_comp(4, $data, 'X456X');
	
	# TEST 5: rollback
	$fh->rollback;
	$fh->seek(0,0);
	$fh->read($data, 40);
	err_comp(5, $data, $org);

	# write some data and commit it
	$fh->seek(4, 0);
	print $fh 'yy';
	$fh->commit;
}
# 
# test: write block
#------------------------------------------------------


#------------------------------------------------------
# check committed file
# 
{
	my ($fh, $data);
	
	$fh = FileHandle->new($path)
		or die "cannot open for write";

	# TEST 6: check committed data
	$fh->read($data, 40);
	err_comp(6, $data, '0123yy6789');
}
# 
# check committed file
#------------------------------------------------------


#------------------------------------------------------
# write out some lines to the test file
# 
reset_file($path, <<"(LINES)");
abcde
abcd
XXX
ab
a
(LINES)
# 
# write out some lines to the test file
#------------------------------------------------------


#------------------------------------------------------
# test line reading
# 
{
	my ($fh, $code);
	my $currtest = 7;
	
	$code = 'abcde';
	
	$fh = FileHandle::Rollback->new("+< $path")
		or die "cannot open filehandle: $!";
	
	# print something right in the middle
	$fh->seek(11, 0);
	print $fh 'abc';
	$fh->seek(0, 0);
	
	# TEST 7: check each line of the file
	while (my $line = <$fh>) {
		chomp $line;
		err_comp($currtest++, $line, $code);
		$code =~ s|.$||;
	}

}
# 
# test line reading
#------------------------------------------------------


# remove test file
unlink $path
	or die "unable to delete test file: $!";


#------------------------------------------------------
# reset_file
# 
sub reset_file {
	my ($path, $content) = @_;
	my ($rfh);
	
	if (-e $path) {
		unlink($path)
			or die "cannot unlink path: $!";
	}
	
	$rfh = FileHandle->new("> $path")
		or die "cannot open for write";
	
	print $rfh $content;
}
# 
# reset_file
#------------------------------------------------------



#------------------------------------------------------
# err_comp
# 
sub err_comp {
	my ($testid, $is, $should) = @_;
	
	if ($is eq $should){
		ok(1);
	}
	
	else {
		ok(0);
	}
	
	#print 
	#	'failed test ',  $testid, ":\n",
	#	'is:     ',      $is, "\n",
	#	'should: ',      $should, "\n";
	#
	#exit;
}
# 
# err_comp
#------------------------------------------------------



# ah, sweet success
# print "all tests passed successfully\n";
