package FileHandle::Rollback;
use strict;
use IO::Handle;
use IO::Seekable;
use Symbol;
use 5.000;
use vars qw($VERSION @ISA);
@ISA = qw(IO::Handle IO::Seekable);

# version
$VERSION = '1.06';


=head1 NAME

FileHandle::Rollback - FileHandle with commit, rollback, and journaled crash recovery

=head1 SYNOPSIS

  use FileHandle::Rollback;
  my ($fh);
  
  # open file handle
  $fh = FileHandle::Rollback->new("+< $path")
    or die "cannot open filehandle: $!";
  
  # put some data at a specific address
  $fh->seek(80, 0);
  print $fh '1500';
  
  # read some data, partially including data 
  # that was written in this rollback segment
  $fh->seek(70, 0);
  $fh->read($data, 100);
  
  # if you want to cancel the changes:
  $fh->rollback;
  
  # or, if you want save the changes:
  $fh->commit;

=head1 INSTALLATION

FileHandle::Rollback can be installed with the usual routine:

	perl Makefile.PL
	make
	make test
	make install

You can also just copy Rollback.pm into the FileHandle/ directory of one of
your library trees.


=head1 DESCRIPTION

FileHandle::Rollback allows you to open a filehandle, write data to that
handle, read the data back exactly as if it were already in the file, then
cancel the whole transaction if you choose. FileHandle::Rollback works like 
FileHandle, with a few important differences, most notably the addition of
C<rollback()> and C<commit()>. Those additions and differences are
noted below.

=head2 $fh->rollback()

Cancels all changes since the last rollback, commit, or since you opened the
file handle.

=head2 $fh->commit()

Writes changes to the file.

=head2 $fh->flock($mode)

The flock method locks the file like the built-in flock command.  Use the same
mode arguments: C<LOCK_SH>, C<LOCK_EX>, and C<LOCK_UN>.

  use Fcntl ':flock';
  
  unless ($fh->flock(LOCK_EX))
    {die "cannot lock filehandle: $!"}

=head2 binmode

FileHandle::Rollback only works in binmode, so it will automatically put
itself into binmode.

=head2 read/write

FileHandle::Rollback only works in read/write mode.  Regardless of what you
begin the file path with (+<, +>, >, >>, etc) FileHandle::Rollback opens the
file with +< .  However, if > is anywhere in the path then
FileHandle::Rollback will create the file if it doesn't already exist.

=head2 autmatic crash recovery

This feature journals the data being written to your file so that if there is
a server crash while the data is being written, FileHandle::Rollback 
automatically finishes the data write.  In short, crash recovery protects you against
invalid data formats: either all the data is written or none of it is.

To implement crash recovery, simply add the C<journal> option to the C<new>
command. C<journal> consists of an anonymous array containing two elements:

 $fh = FileHandle::Rollback->new('members.db', journal=>['members.journal', 'members.sem'])
    or die $!;

The first element is the file name of a "journal" file, a file where 
data is temporarily stored before being written to the real data file.
The second element is the file name of a "semaphore" file whose
existence indicates that data is being written to the data file.

When a FileHandle::Rollback object is created with journaling, the first thing
it does is check if the semaphore file exists.  If that file does exist, then
the object knows that there was a crash the last time the data was being written.
The object pulls the stored data from the journal file and tries again to write
the data to the data file.  Once the data is fully written, it deletes the 
semaphore and journal files.

This form of crash recovery is dependent on the atomicity of file
creation and deletion on your computer, so on some systems (particularly
NFS) there is a small chance that crash recovery will not work properly.
Caveat programmer.

=cut


#--------------------------------------------------------------------------------------
# new
# 
sub new {
	my($class, $path, %opts) = @_;
	my $fh = gensym;
	my $orgpath = $path;
	
	# file MUST be opened read/write
	# so ignore open directives
	$path =~ s|^[\+\<\> ]+||s;
	
	# if file was opened for creation
	if (
		(! -e $path) && 
		($orgpath =~ m|\>|)
		) {
		FileHandle->new("> $path")
			or die "unable to create $path: $!"
	}
	
	# set open string to read/write
	$path = "+< $path";
	
	${*$fh} = tie *$fh, 'FileHandle::Rollback::Tie', $path, %opts;
	bless $fh, $class;
	return $fh;
}
# 
# new
#--------------------------------------------------------------------------------------


sub seek {
    my $fh = shift;
    ${*$fh}->SEEK( @_ );
}

sub tell {
    my $fh = shift;
    ${*$fh}->TELL( @_ );
}

sub flock {
	my $fh = shift;
	return ${*$fh}->FLOCK(@_);
}

sub write {
	my $fh = shift;
	${*$fh}->WRITE(@_);
}

sub rollback {
    my $fh = shift;
    ${*$fh}->rollback(@_);
}

sub commit {
    my $fh = shift;
    ${*$fh}->commit(@_);
}


###############################################################################
# FileHandle::Rollback::Tie
# 
package FileHandle::Rollback::Tie;
use strict;
use vars qw($VERSION);
use IO::Seekable;
use FileHandle;

use 5.000;
$VERSION = '0.06';


# Preloaded methods go here.
sub TIEHANDLE {
	my($class, $openstr, %opts) = @_;
	my $self = bless({}, $class);
	my ($fh);
	
	# open the "real" file handle
	$fh = FileHandle->new($openstr)
		or return undef;
	binmode $fh;
	
	# get length of file
	$fh->seek(0,2);
	$self->{'orgmax'} = $fh->tell;
	$fh->seek(0,0);
	
	# properties
	$self->{'fh'} = $fh;
	$self->{'tell'} = 0;
	
	# set up first rollback segment
	$self->rollback;

	# hold on to journal options
	if ($opts{'journal'}) {
		$self->{'journal'} = {
			journal   => $opts{'journal'}->[0], 
			semaphore => $opts{'journal'}->[1],
			};
		
		# if the semaphore file exists, that means
		# that there was a crash during the last write attempt
		if (-e($self->{'journal'}->{'semaphore'})) {
			my ($journal, @frozen);
			require Data::Taxi;
			
			$journal = FileHandle->new($self->{'journal'}->{'journal'})
				or return(undef);
			
			while (my $line = <$journal>)
				{push @frozen, $line}
			
			undef $journal;
			
			$self->{'blocks'} = Data::Taxi::thaw(join('', @frozen));
			
			if ($self->commit(skip_journal=>1)) {
				unlink($self->{'journal'}->{'semaphore'})
					or return(undef);
				unlink($self->{'journal'}->{'journal'})
					or return(undef);
			}
			
			else
				{return undef}
		}
	}
	
	return $self;
}

sub rollback {
	my ($self) = @_;

	$self->{'blocks'} = [];
	$self->{'max'} = $self->{'orgmax'};
	
	$self->{'tell'} > $self->{'max'} and
		$self->{'tell'} = $self->{'max'};
	
	return 1;
}

sub commit {
	my ($self, %opts) = @_;
	my $fh = $self->{'fh'};
	
	# journal if called upon to do so
	if ($self->{'journal'} && (! $opts{'skip_journal'}) ) {
		my ($journal, $taxi);
		require Data::Taxi;
		
		$journal = FileHandle->new("> $self->{'journal'}->{'journal'}")
			or return(undef);
		
		$taxi = Data::Taxi::freeze($self->{'blocks'});
		print $journal $taxi;
		$journal->close();
		undef $journal;
		
		FileHandle->new("> $self->{'journal'}->{'semaphore'}")
			or return(undef);
	}
	
	# write data blocks
	foreach my $block (@{$self->{'blocks'}}) {
		$fh->seek($block->{'pos'}, 0);
		my $res = print $fh $block->{'data'};
		$res or return(undef);
	}
	
	# remove semaphore
	if ($self->{'journal'} && (! $opts{'skip_journal'}) ) {
		unlink($self->{'journal'}->{'semaphore'})
			or return(undef);
		unlink($self->{'journal'}->{'journal'})
			or return(undef);
	}
	
	# reset
	$self->{'orgmax'} = $self->{'max'};
	$self->{'blocks'} = [];
	
	return 1;
}


sub READLINE {
	my $self = shift;
	my ($rv, $data, $holdtell);
	
	# if EOF, return undef
	if ($self->{'tell'} >= $self->{'max'})
		{return undef}
	
	$holdtell = $self->{'tell'};
	$rv = '';
	
	LINELOOP:
	while ($self->{'tell'} < $self->{'max'}) {
		$self->READ($data, 128);
		$rv .= $data;
		
		if ($rv =~ s|$/.*|$/|s)
			{last LINELOOP}
	}
	
	$self->{'tell'} = $holdtell + length($rv);
	
	return $rv;	
}

# READ
sub READ {
	my $self = shift;
	local *FileHandle::Rollback::Tie::buf = \shift;
	my( $len, $offset ) = @_;
	$offset ||= 0;
	
	my (@data, $firstblock, $readamt, $inpos, $mid);
	my $remain = $len;
	my $blockidx = 0;
	my $fh = $self->{'fh'};
	
	# find first block that tell is in or before
	BLOCKLOOP:
	foreach my $block (@{$self->{'blocks'}}) {
		# if tell is BEFORE block
		if ($self->{'tell'} < $block->{'pos'})
			{last BLOCKLOOP}
		
		# if tell is in this block
		if (
			($self->{'tell'} >= $block->{'pos'}) &&
			($self->{'tell'} <= $block->{'pos'}+ length($block->{'data'}))
			) {
			# set that we should process first block			
			$firstblock = 1;
			
			# set inpos to position in first block
			$inpos = $self->{'tell'} - $block->{'pos'};
			
			last BLOCKLOOP;
		}
		
		$blockidx++;
	}
	
	# while remain is greater than zero
	READLOOP:
	while ($remain > 0) {
		my ($block);
		
		# if firstblock
		if ($firstblock) {
			my ($len);
			$block = $self->{'blocks'}->[$blockidx];
			
			# get substr starting at inpos
			$mid = substr($block->{'data'}, $inpos, $remain);
			$len = length($mid);
			
			# substract length of substr from remain
			$remain -= $len;
			
			$self->{'tell'} += $len;
			push @data, $mid;
			
			# if tell >= max, last loop
			if ($self->{'tell'} >= $self->{'max'})
				{last READLOOP}
			
			$blockidx++;
		}
		
		$firstblock = 1;
		$inpos = 0;
		
		# if there is still anything remaining to be gotten
		if ($remain > 0) {
			my ($readamt);
			
			# go first position in file after block
			if ($block)
				{$fh->seek($block->{'pos'} + length($block->{'data'}), 0)}
			else
				{$fh->seek($self->{'tell'},0)}
			
			# if next block
			if ($self->{'blocks'}->[$blockidx]) {
				# readamt = amount till next block
				$readamt = $self->{'blocks'}->[$blockidx]->{'pos'} - $self->{'tell'};
				
				# if remain is less than readamt
				$remain < $readamt and $readamt = $remain;
			}
			else
				{$readamt = $remain}
			
			# read readamt bytes from file
			$fh->read($mid, $readamt);
			
			$self->{'tell'} += length($mid);
			push @data, $mid;
			
			if ($self->{'tell'} >= $self->{'max'})
				{last READLOOP}
			
			$remain -= $readamt;
		}
		
	}
	
	defined($FileHandle::Rollback::Tie::buf) or $FileHandle::Rollback::Tie::buf='';
	substr( $FileHandle::Rollback::Tie::buf, $offset, $len) = join('', @data);
	
	return length($FileHandle::Rollback::Tie::buf);
}


sub GETC {
    my $self = shift;
	my ($rv);

	$self->READ($rv, 1);
	return $rv;
}


sub WRITE {
	my ($self, $buf, $len, $offset) = @_;
	$offset ||= 0;
	
	$self->PRINT(substr( $buf, $len, $offset ));

	$len;
}


# PRINT
sub PRINT {
	my $self = shift;
	my $data = join('', @_);
	my $i = 0;
	my $len = length($data);
	my $orgtell = $self->{'tell'};
	my ($new);
	
	# adjust current position
	$self->{'tell'} += $len;	
	$self->{'max'} < $self->{'tell'} and $self->{'max'} = $self->{'tell'};
	
	# loop through segments looking for 
	# this position
	SEGLOOP:
	foreach my $block (@{$self->{'blocks'}}) {
		# if the current tell position is within this block or before it
		if ( $orgtell <=  ($block->{'pos'} + length($block->{'data'})  ) ) {
			# if we need to insert a new block
			if ($orgtell < $block->{'pos'} ) {
				splice @{$self->{'blocks'}}, $i, 0, {'pos'=>$orgtell, 'data'=>$data };
				$new = 1;
			}
			
			last SEGLOOP;
		}
		
		$i++;
	}
	
	# add block at end if necessary
	if ($i > $#{ $self->{'blocks'} })
		{push @{ $self->{'blocks'} }, {'pos'=>$orgtell, 'data'=>$data }}
	
	# else we found a block in which this string should be added
	else {
		my ($before);
		my $block = $self->{'blocks'}->[$i];
		my $inpos = $orgtell - $block->{'pos'};

		# get everything in the existing block up to
		# but not including the current position
		$before = substr($block->{'data'}, 0, $inpos);
		
		# if remaining existing data is longer than new data
		if (
			(! $new) && 
			(length($block->{'data'})-$inpos+1 > $len)
			) {
			$block->{'data'} = 
				$before . 
				$data . 
				substr($block->{'data'}, $inpos + $len );
		}
		
		# else we're possibly overlapping into the next block
		else {
			# data now equals before + new data
			$block->{'data'} = $before . $data;
			
			# get next blocks while they overlap 
			# this block
			my ($next);
			
			# while this is overlaps the next block
			while (
				# while there IS a next block
				$i < $#{$self->{'blocks'}} and
				$self->{'tell'} >= $self->{'blocks'}->[$i+1]->{'pos'}
				) {
				($next) = splice( @{$self->{'blocks'}}, $i+1, 1 );
			}
			
			# if we haven't completely overwritten the 
			# last block, add what's left to this block
			if (
				$next && 
				(! ($next->{'pos'} + length($next->{'data'}) <= $self->{'tell'}))
				) {
				$block->{'data'} .= substr($next->{'data'}, $self->{'tell'} - $next->{'pos'});
			}
		}
	}
	
	return 1;
}



#------------------------------------------------
# PRINTF
# 
sub PRINTF {
	my $self = shift;
	return $self->PRINT(sprintf( shift, @_ ));
}
#
# PRINTF
#------------------------------------------------


#------------------------------------------------
# CLOSE
# 
sub CLOSE {
    my $self = shift;
    untie $self;
    $self;
}
# 
# CLOSE
#------------------------------------------------


sub SEEK {
	my( $self, $pos, $whence ) = @_;
	
	if ( $whence == SEEK_SET )
		{}
	elsif ( $whence == SEEK_CUR )
		{$pos += $self->{'tell'}}
	elsif ( $whence == SEEK_END ) {
		$pos = $self->{'max'} - $pos;
		$pos < 0  and $pos = 0;
		return 1;
	}
	else
		{return 0}
	
	if ( $pos <= $self->{'max'} ) {
		$self->{'tell'} = $pos;
		return 1;
	}
	
	return 0;
}

sub TELL {
	my ($self) = @_;
	return $self->{'tell'};
}

sub FLOCK {
	my ($self, $mode) = @_;
	my $fh = $self->{'fh'};
	return flock($fh, $mode);
}

# does nothing, already in binmode
sub BINMODE {
	#my ($self) = @_;
}


# 
# FileHandle::Rollback::Tie
###############################################################################


# return true
1;


__END__


=head1 TERMS AND CONDITIONS

Copyright (C) 2002, 2003 Miko O'Sullivan

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
02111-1307  USA


=head1 AUTHOR

Miko O'Sullivan
F<miko@idocs.com>

A lot of the code in this module was copied from MemHandle.pm by Sheridan C.
Rawlins.  In fact, I started with Sheridan's module and just changed code
until it worked the way I wanted, so Sheridan gets a lot of credit for
FileHandle::Rollback.

=head1 VERSION

  Version 1.00, June 29, 2002
  First public release
  
  Version 1.01, June 30, 2002
  Minor tweaks to 1.00
  
  Version 1.02, June 30, 2002
  Small but important correction to documentation
  
  Version 1.03, July 1, 2002
  Another small but important correction to documentation.
  
  Version 1.04, July 10, 2002
  Yet another small but important correction to documentation.  Sheesh.
  
  and then a long time went by...
  
  Version 1.05, June 12, 2003
  Added journaled automatic crash recovery

  Version 1.06, July 28, 2007
  No changes to module, changed bogus package for CPAN


=cut
