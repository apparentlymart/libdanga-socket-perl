###########################################################################

=head1 NAME

Danga::Socket - Event loop and event-driven async socket base class

=head1 SYNOPSIS

  package My::Socket
  use Danga::Socket;
  use base ('Danga::Socket');
  use fields ('my_attribute');

  sub new {
     my My::Socket $self = shift;
     $self = fields::new($self) unless ref $self;
     $self->SUPER::new( @_ );

     $self->{my_attribute} = 1234;
     return $self;
  }

  sub event_err { ... }
  sub event_hup { ... }
  sub event_write { ... }
  sub event_read { ... }
  sub close { ... }

  $my_sock->tcp_cork($bool);

  # write returns 1 if all writes have gone through, or 0 if there
  # are writes in queue
  $my_sock->write($scalar);
  $my_sock->write($scalarref);
  $my_sock->write(sub { ... });  # run when previous data written
  $my_sock->write(undef);        # kick-starts

  # read max $bytecount bytes, or undef on connection closed
  $scalar_ref = $my_sock->read($bytecount);

  # watch for writability.  not needed with ->write().  write()
  # will automatically turn on watch_write when you wrote too much
  # and turn it off when done
  $my_sock->watch_write($bool);

  # watch for readability
  $my_sock->watch_read($bool);

  # if you read too much and want to push some back on
  # readable queue.  (not incredibly well-tested)
  $my_sock->push_back_read($buf); # scalar or scalar ref

  Danga::Socket->AddOtherFds(..);
  Danga::Socket->SetLoopTimeout($millisecs);
  Danga::Socket->DescriptorMap();
  Danga::Socket->WatchedSockets();  # count of DescriptorMap keys
  Danga::Socket->SetPostLoopCallback($code);
  Danga::Socket->EventLoop();

=head1 DESCRIPTION

This is an abstract base class for objects backed by a socket which
provides the basic framework for event-driven asynchronous IO,
designed to be fast.  Danga::Socket is both a base class for objects,
and an event loop.

Callers subclass Danga::Socket.  Danga::Socket's constructor registers
itself with the Danga::Socket event loop, and invokes callbacks on the
object for readability, writability, errors, and other conditions.

Because Danga::Socket uses the "fields" module, your subclasses must
too.

=head1 MORE INFO

For now, see servers using Danga::Socket for guidance.  For example:
perlbal, mogilefsd, or ddlockd.

=head1 API

Note where "C<CLASS>" is used below, normally you would call these methods as:

  Danga::Socket->method(...);

However using a subclass works too.

The CLASS methods are all methods for the event loop part of Danga::Socket,
whereas the object methods are all used on your subclasses.

=cut

###########################################################################

package Danga::Socket;
use strict;
use bytes;
use POSIX ();
use Time::HiRes ();
use AnyEvent;

my $opt_bsd_resource = eval "use BSD::Resource; 1;";

use vars qw{$VERSION};
$VERSION = "1.61";

use warnings;
no  warnings qw(deprecated);

use Sys::Syscall qw(:epoll);

use fields ('sock',              # underlying socket
            'fd',                # numeric file descriptor
            'write_buf',         # arrayref of scalars, scalarrefs, or coderefs to write
            'write_buf_offset',  # offset into first array of write_buf to start writing at
            'write_buf_size',    # total length of data in all write_buf items
            'write_set_watch',   # bool: true if we internally set watch_write rather than by a subclass
            'read_push_back',    # arrayref of "pushed-back" read data the application didn't want
            'closed',            # bool: socket is closed
            'corked',            # bool: socket is corked
            'event_watch',       # bitmask of events the client is interested in (POLLIN,OUT,etc.)
            'peer_v6',           # bool: cached; if peer is an IPv6 address
            'peer_ip',           # cached stringified IP address of $sock
            'peer_port',         # cached port number of $sock
            'local_ip',          # cached stringified IP address of local end of $sock
            'local_port',        # cached port number of local end of $sock
            'writer_func',       # subref which does writing.  must return bytes written (or undef) and set $! on errors
            );

use Errno  qw(EINPROGRESS EWOULDBLOCK EISCONN ENOTSOCK
              EPIPE EAGAIN EBADF ECONNRESET ENOPROTOOPT);
use Socket qw(IPPROTO_TCP);
use Carp   qw(croak confess);

use constant TCP_CORK => ($^O eq "linux" ? 3 : 0); # FIXME: not hard-coded (Linux-specific too)
use constant DebugLevel => 0;

use constant POLLIN        => 1;
use constant POLLOUT       => 4;
use constant POLLERR       => 8;
use constant POLLHUP       => 16;
use constant POLLNVAL      => 32;

our $HAVE_KQUEUE = eval { require IO::KQueue; 1 };

our (
     %Timers,                    # timers
     %FdWatchers,                # fd (num) -> [ AnyEvent read watcher, AnyEvent write watcher ]
     %DescriptorMap,             # fd (num) -> Danga::Socket object that owns it
     %OtherFds,                  # fd (num) -> sub to run when that fd is ready to read or write

    # Legacy bits that still need porting or eradicating
     $HaveEpoll, $HaveKQueue,    # no longer used
     %PushBackSet,               # fd (num) -> Danga::Socket (fds with pushed back read data)
     $Epoll,                     # Global epoll fd (for epoll mode only)
     $KQueue,                    # Global kqueue fd (for kqueue mode only)
     @ToClose,                   # sockets to close when event loop is done

     $PostLoopCallback,          # subref to call at the end of each loop, if defined (global)
     %PLCMap,                    # fd (num) -> PostLoopCallback (per-object)

     $LoopTimeout,               # timeout of event loop in milliseconds
     $DoProfile,                 # if on, enable profiling
     %Profiling,                 # what => [ utime, stime, calls ]
     $DoneInit,                  # if we've done the one-time module init yet
     );

Reset();

#####################################################################
### C L A S S   M E T H O D S
#####################################################################

=head2 C<< CLASS->Reset() >>

Reset all state

=cut
sub Reset {
    %Timers = ();
    %FdWatchers = ();
    %DescriptorMap = ();
    %OtherFds = ();
}

=head2 C<< CLASS->HaveEpoll() >>

Returns a true value if this class will use IO::Epoll for async IO.

=cut
sub HaveEpoll {
    return 1;
}

=head2 C<< CLASS->WatchedSockets() >>

Returns the number of file descriptors for which we have watchers installed.

=cut
sub WatchedSockets {
    return scalar(keys(%FdWatchers));
}
*watched_sockets = *WatchedSockets;

=head2 C<< CLASS->EnableProfiling() >>

Turns profiling on, clearing current profiling data.

=cut
sub EnableProfiling {
    if ($opt_bsd_resource) {
        %Profiling = ();
        $DoProfile = 1;
        return 1;
    }
    return 0;
}

=head2 C<< CLASS->DisableProfiling() >>

Turns off profiling, but retains data up to this point

=cut
sub DisableProfiling {
    $DoProfile = 0;
}

=head2 C<< CLASS->ProfilingData() >>

Returns reference to a hash of data in format:

  ITEM => [ utime, stime, #calls ]

=cut
sub ProfilingData {
    return \%Profiling;
}

=head2 C<< CLASS->ToClose() >>

Return the list of sockets that are awaiting close() at the end of the
current event loop.

=cut
sub ToClose { return @ToClose; }

=head2 C<< CLASS->OtherFds( [%fdmap] ) >>

Get/set the hash of file descriptors that need processing in parallel with
the registered Danga::Socket objects.

Callers must not modify the returned hash.

=cut
sub OtherFds {
    my $class = shift;
    if ( @_ ) {
        # Clean up any watchers that we no longer need.
        foreach my $fd (keys %OtherFds) {
            delete $FdWatchers{$fd};
        }
        %OtherFds = ();
        $class->AddOtherFds(@_);
    }
    return wantarray ? %OtherFds : \%OtherFds;
}

=head2 C<< CLASS->AddOtherFds( [%fdmap] ) >>

Add fds to the OtherFds hash for processing.

=cut
sub AddOtherFds {
    my ($class, %fdmap) = @_;

    foreach my $fd (keys %fdmap) {
        my $coderef = $fdmap{$fd};
        $OtherFds{$fd} = $coderef;

        # The OtherFds interface uses the same callback for both read and write events,
        # so create two AnyEvent watchers that differ only in their mode.
        $FdWatchers{$fd} = [ map {
            my $mode = $_;
            AnyEvent->io(
                fh => $fd,
                poll => $mode,
                cb => $coderef,
            )
        } qw(r w) ];
    }
}

=head2 C<< CLASS->SetLoopTimeout( $timeout ) >>

Set the loop timeout for the event loop to some value in milliseconds.

A timeout of 0 (zero) means poll forever. A timeout of -1 means poll and return
immediately.

=cut
sub SetLoopTimeout {
    return $LoopTimeout = $_[1] + 0;
}

=head2 C<< CLASS->DebugMsg( $format, @args ) >>

Print the debugging message specified by the C<sprintf>-style I<format> and
I<args>

=cut
sub DebugMsg {
    my ( $class, $fmt, @args ) = @_;
    chomp $fmt;
    printf STDERR ">>> $fmt\n", @args;
}

=head2 C<< CLASS->AddTimer( $seconds, $coderef ) >>

Add a timer to occur $seconds from now. $seconds may be fractional, but timers
are not guaranteed to fire at the exact time you ask for.

Returns a timer object which you can call C<< $timer->cancel >> on if you need to.

=cut
sub AddTimer {
    my $class = shift;
    my ($secs, $coderef) = @_;

    my $timer = [ undef ];

    my $key = "$timer"; # Just stringify the timer array to get our hash key

    my $cancel = sub {
        delete $Timers{$key};
    };

    my $cb = sub {
        $coderef->();
        $cancel->();
    };

    $timer->[0] = $cancel;

    # We save the watcher in $Timers to keep it alive until it runs,
    # or until $cancel above overwrites it with undef to cause it to
    # get collected.
    $Timers{$key} = AnyEvent->timer(
        after => $secs,
        cb => $cb,
    );

    return bless $timer, 'Danga::Socket::Timer';
}

=head2 C<< CLASS->DescriptorMap() >>

Get the hash of Danga::Socket objects keyed by the file descriptor (fileno) they
are wrapping.

Returns a hash in list context or a hashref in scalar context.

=cut
sub DescriptorMap {
    return wantarray ? %DescriptorMap : \%DescriptorMap;
}
*descriptor_map = *DescriptorMap;
*get_sock_ref = *DescriptorMap;

=head2 C<< CLASS->EventLoop() >>

Start processing IO events. In most daemon programs this never exits. See
C<PostLoopCallback> below for how to exit the loop.

=cut

sub EventLoop {
    my $class = shift;

    my $cv = AnyEvent->condvar;

    # Set up an idle watcher to call the post loop handler
    my $idle_watcher = AnyEvent->idle(cb => sub {
        my $should_continue = $class->PostEventLoop();
        $cv->send() unless $should_continue;
    });

    $cv->recv(); # Blocks until we call $cv->send above
}

## profiling-related data/functions
our ($Prof_utime0, $Prof_stime0);
sub _pre_profile {
    ($Prof_utime0, $Prof_stime0) = getrusage();
}

sub _post_profile {
    # get post information
    my ($autime, $astime) = getrusage();

    # calculate differences
    my $utime = $autime - $Prof_utime0;
    my $stime = $astime - $Prof_stime0;

    foreach my $k (@_) {
        $Profiling{$k} ||= [ 0.0, 0.0, 0 ];
        $Profiling{$k}->[0] += $utime;
        $Profiling{$k}->[1] += $stime;
        $Profiling{$k}->[2]++;
    }
}

=head2 C<< CLASS->SetPostLoopCallback( CODEREF ) >>

Sets post loop callback function.  Pass a subref and it will be
called every time the event loop finishes.

Return 1 (or any true value) from the sub to make the loop continue, 0 or false
and it will exit.

The callback function will be passed two parameters: \%DescriptorMap, \%OtherFds.

=cut
sub SetPostLoopCallback {
    my ($class, $ref) = @_;

    if (ref $class) {
        # per-object callback
        my Danga::Socket $self = $class;
        if (defined $ref && ref $ref eq 'CODE') {
            $PLCMap{$self->{fd}} = $ref;
        } else {
            delete $PLCMap{$self->{fd}};
        }
    } else {
        # global callback
        $PostLoopCallback = (defined $ref && ref $ref eq 'CODE') ? $ref : undef;
    }
}

# Internal function: run the post-event callback, send read events
# for pushed-back data, and close pending connections.  returns 1
# if event loop should continue, or 0 to shut it all down.
sub PostEventLoop {
    return 1;
}

#####################################################################
### Danga::Socket-the-object code
#####################################################################

=head2 OBJECT METHODS

=head2 C<< CLASS->new( $socket ) >>

Create a new Danga::Socket subclass object for the given I<socket> which will
react to events on it during the C<EventLoop>.

This is normally (always?) called from your subclass via:

  $class->SUPER::new($socket);

=cut
sub new {
    my Danga::Socket $self = shift;
    $self = fields::new($self) unless ref $self;

    my $sock = shift;

    $self->{sock}        = $sock;
    my $fd = fileno($sock);

    Carp::cluck("undef sock and/or fd in Danga::Socket->new.  sock=" . ($sock || "") . ", fd=" . ($fd || ""))
        unless $sock && $fd;

    $self->{fd}          = $fd;
    $self->{write_buf}      = [];
    $self->{write_buf_offset} = 0;
    $self->{write_buf_size} = 0;
    $self->{closed} = 0;
    $self->{corked} = 0;
    $self->{read_push_back} = [];

    $self->{event_watch} = POLLERR|POLLHUP|POLLNVAL;

    _InitPoller();

    if ($HaveEpoll) {
        epoll_ctl($Epoll, EPOLL_CTL_ADD, $fd, $self->{event_watch})
            and die "couldn't add epoll watch for $fd\n";
    }
    elsif ($HaveKQueue) {
        # Add them to the queue but disabled for now
        $KQueue->EV_SET($fd, IO::KQueue::EVFILT_READ(),
                        IO::KQueue::EV_ADD() | IO::KQueue::EV_DISABLE());
        $KQueue->EV_SET($fd, IO::KQueue::EVFILT_WRITE(),
                        IO::KQueue::EV_ADD() | IO::KQueue::EV_DISABLE());
    }

    Carp::cluck("Danga::Socket::new blowing away existing descriptor map for fd=$fd ($DescriptorMap{$fd})")
        if $DescriptorMap{$fd};

    $DescriptorMap{$fd} = $self;
    return $self;
}


#####################################################################
### I N S T A N C E   M E T H O D S
#####################################################################

=head2 C<< $obj->tcp_cork( $boolean ) >>

Turn TCP_CORK on or off depending on the value of I<boolean>.

=cut
sub tcp_cork {
    my Danga::Socket $self = $_[0];
    my $val = $_[1];

    # make sure we have a socket
    return unless $self->{sock};
    return if $val == $self->{corked};

    my $rv;
    if (TCP_CORK) {
        $rv = setsockopt($self->{sock}, IPPROTO_TCP, TCP_CORK,
                         pack("l", $val ? 1 : 0));
    } else {
        # FIXME: implement freebsd *PUSH sockopts
        $rv = 1;
    }

    # if we failed, close (if we're not already) and warn about the error
    if ($rv) {
        $self->{corked} = $val;
    } else {
        if ($! == EBADF || $! == ENOTSOCK) {
            # internal state is probably corrupted; warn and then close if
            # we're not closed already
            warn "setsockopt: $!";
            $self->close('tcp_cork_failed');
        } elsif ($! == ENOPROTOOPT || $!{ENOTSOCK} || $!{EOPNOTSUPP}) {
            # TCP implementation doesn't support corking, so just ignore it
            # or we're trying to tcp-cork a non-socket (like a socketpair pipe
            # which is acting like a socket, which Perlbal does for child
            # processes acting like inetd-like web servers)
        } else {
            # some other error; we should never hit here, but if we do, die
            die "setsockopt: $!";
        }
    }
}

=head2 C<< $obj->steal_socket() >>

Basically returns our socket and makes it so that we don't try to close it,
but we do remove it from epoll handlers.  THIS CLOSES $self.  It is the same
thing as calling close, except it gives you the socket to use.

=cut
sub steal_socket {
    my Danga::Socket $self = $_[0];
    return if $self->{closed};

    # cleanup does most of the work of closing this socket
    $self->_cleanup();

    # now undef our internal sock and fd structures so we don't use them
    my $sock = $self->{sock};
    $self->{sock} = undef;
    return $sock;
}

=head2 C<< $obj->close( [$reason] ) >>

Close the socket. The I<reason> argument will be used in debugging messages.

=cut
sub close {
    my Danga::Socket $self = $_[0];
    return if $self->{closed};

    # print out debugging info for this close
    if (DebugLevel) {
        my ($pkg, $filename, $line) = caller;
        my $reason = $_[1] || "";
        warn "Closing \#$self->{fd} due to $pkg/$filename/$line ($reason)\n";
    }

    # this does most of the work of closing us
    $self->_cleanup();

    # defer closing the actual socket until the event loop is done
    # processing this round of events.  (otherwise we might reuse fds)
    if ($self->{sock}) {
        push @ToClose, $self->{sock};
        $self->{sock} = undef;
    }

    return 0;
}

### METHOD: _cleanup()
### Called by our closers so we can clean internal data structures.
sub _cleanup {
    my Danga::Socket $self = $_[0];

    # we're effectively closed; we have no fd and sock when we leave here
    $self->{closed} = 1;

    # we need to flush our write buffer, as there may
    # be self-referential closures (sub { $client->close })
    # preventing the object from being destroyed
    $self->{write_buf} = [];

    # uncork so any final data gets sent.  only matters if the person closing
    # us forgot to do it, but we do it to be safe.
    $self->tcp_cork(0);

    # if we're using epoll, we have to remove this from our epoll fd so we stop getting
    # notifications about it
    if ($HaveEpoll && $self->{fd}) {
        if (epoll_ctl($Epoll, EPOLL_CTL_DEL, $self->{fd}, $self->{event_watch}) != 0) {
            # dump_error prints a backtrace so we can try to figure out why this happened
            $self->dump_error("epoll_ctl(): failure deleting fd=$self->{fd} during _cleanup(); $! (" . ($!+0) . ")");
        }
    }

    # now delete from mappings.  this fd no longer belongs to us, so we don't want
    # to get alerts for it if it becomes writable/readable/etc.
    delete $PushBackSet{$self->{fd}};
    delete $PLCMap{$self->{fd}};

    # we explicitly don't delete from DescriptorMap here until we
    # actually close the socket, as we might be in the middle of
    # processing an epoll_wait/etc that returned hundreds of fds, one
    # of which is not yet processed and is what we're closing.  if we
    # keep it in DescriptorMap, then the event harnesses can just
    # looked at $pob->{closed} and ignore it.  but if it's an
    # un-accounted for fd, then it (understandably) freak out a bit
    # and emit warnings, thinking their state got off.

    # and finally get rid of our fd so we can't use it anywhere else
    $self->{fd} = undef;
}

=head2 C<< $obj->sock() >>

Returns the underlying IO::Handle for the object.

=cut
sub sock {
    my Danga::Socket $self = shift;
    return $self->{sock};
}

=head2 C<< $obj->set_writer_func( CODEREF ) >>

Sets a function to use instead of C<syswrite()> when writing data to the socket.

=cut
sub set_writer_func {
   my Danga::Socket $self = shift;
   my $wtr = shift;
   Carp::croak("Not a subref") unless !defined $wtr || UNIVERSAL::isa($wtr, "CODE");
   $self->{writer_func} = $wtr;
}

=head2 C<< $obj->write( $data ) >>

Write the specified data to the underlying handle.  I<data> may be scalar,
scalar ref, code ref (to run when there), or undef just to kick-start.
Returns 1 if writes all went through, or 0 if there are writes in queue. If
it returns 1, caller should stop waiting for 'writable' events)

=cut
sub write {
    my Danga::Socket $self;
    my $data;
    ($self, $data) = @_;

    # nobody should be writing to closed sockets, but caller code can
    # do two writes within an event, have the first fail and
    # disconnect the other side (whose destructor then closes the
    # calling object, but it's still in a method), and then the
    # now-dead object does its second write.  that is this case.  we
    # just lie and say it worked.  it'll be dead soon and won't be
    # hurt by this lie.
    return 1 if $self->{closed};

    my $bref;

    # just queue data if there's already a wait
    my $need_queue;

    if (defined $data) {
        $bref = ref $data ? $data : \$data;
        if ($self->{write_buf_size}) {
            push @{$self->{write_buf}}, $bref;
            $self->{write_buf_size} += ref $bref eq "SCALAR" ? length($$bref) : 1;
            return 0;
        }

        # this flag says we're bypassing the queue system, knowing we're the
        # only outstanding write, and hoping we don't ever need to use it.
        # if so later, though, we'll need to queue
        $need_queue = 1;
    }

  WRITE:
    while (1) {
        return 1 unless $bref ||= $self->{write_buf}[0];

        my $len;
        eval {
            $len = length($$bref); # this will die if $bref is a code ref, caught below
        };
        if ($@) {
            if (UNIVERSAL::isa($bref, "CODE")) {
                unless ($need_queue) {
                    $self->{write_buf_size}--; # code refs are worth 1
                    shift @{$self->{write_buf}};
                }
                $bref->();

                # code refs are just run and never get reenqueued
                # (they're one-shot), so turn off the flag indicating the
                # outstanding data needs queueing.
                $need_queue = 0;

                undef $bref;
                next WRITE;
            }
            die "Write error: $@ <$bref>";
        }

        my $to_write = $len - $self->{write_buf_offset};
        my $written;
        if (my $wtr = $self->{writer_func}) {
            $written = $wtr->($bref, $to_write, $self->{write_buf_offset});
        } else {
            $written = syswrite($self->{sock}, $$bref, $to_write, $self->{write_buf_offset});
        }

        if (! defined $written) {
            if ($! == EPIPE) {
                return $self->close("EPIPE");
            } elsif ($! == EAGAIN) {
                # since connection has stuff to write, it should now be
                # interested in pending writes:
                if ($need_queue) {
                    push @{$self->{write_buf}}, $bref;
                    $self->{write_buf_size} += $len;
                }
                $self->{write_set_watch} = 1 unless $self->{event_watch} & POLLOUT;
                $self->watch_write(1);
                return 0;
            } elsif ($! == ECONNRESET) {
                return $self->close("ECONNRESET");
            }

            DebugLevel >= 1 && $self->debugmsg("Closing connection ($self) due to write error: $!\n");

            return $self->close("write_error");
        } elsif ($written != $to_write) {
            DebugLevel >= 2 && $self->debugmsg("Wrote PARTIAL %d bytes to %d",
                                               $written, $self->{fd});
            if ($need_queue) {
                push @{$self->{write_buf}}, $bref;
                $self->{write_buf_size} += $len;
            }
            # since connection has stuff to write, it should now be
            # interested in pending writes:
            $self->{write_buf_offset} += $written;
            $self->{write_buf_size} -= $written;
            $self->on_incomplete_write;
            return 0;
        } elsif ($written == $to_write) {
            DebugLevel >= 2 && $self->debugmsg("Wrote ALL %d bytes to %d (nq=%d)",
                                               $written, $self->{fd}, $need_queue);
            $self->{write_buf_offset} = 0;

            if ($self->{write_set_watch}) {
                $self->watch_write(0);
                $self->{write_set_watch} = 0;
            }

            # this was our only write, so we can return immediately
            # since we avoided incrementing the buffer size or
            # putting it in the buffer.  we also know there
            # can't be anything else to write.
            return 1 if $need_queue;

            $self->{write_buf_size} -= $written;
            shift @{$self->{write_buf}};
            undef $bref;
            next WRITE;
        }
    }
}

sub on_incomplete_write {
    my Danga::Socket $self = shift;
    $self->{write_set_watch} = 1 unless $self->{event_watch} & POLLOUT;
    $self->watch_write(1);
}

=head2 C<< $obj->push_back_read( $buf ) >>

Push back I<buf> (a scalar or scalarref) into the read stream. Useful if you read
more than you need to and want to return this data on the next "read".

=cut
sub push_back_read {
    my Danga::Socket $self = shift;
    my $buf = shift;
    push @{$self->{read_push_back}}, ref $buf ? $buf : \$buf;
    $PushBackSet{$self->{fd}} = $self;
}

=head2 C<< $obj->read( $bytecount ) >>

Read at most I<bytecount> bytes from the underlying handle; returns scalar
ref on read, or undef on connection closed.

=cut
sub read {
    my Danga::Socket $self = shift;
    return if $self->{closed};
    my $bytes = shift;
    my $buf;
    my $sock = $self->{sock};

    if (@{$self->{read_push_back}}) {
        $buf = shift @{$self->{read_push_back}};
        my $len = length($$buf);

        if ($len <= $bytes) {
            delete $PushBackSet{$self->{fd}} unless @{$self->{read_push_back}};
            return $buf;
        } else {
            # if the pushed back read is too big, we have to split it
            my $overflow = substr($$buf, $bytes);
            $buf = substr($$buf, 0, $bytes);
            unshift @{$self->{read_push_back}}, \$overflow;
            return \$buf;
        }
    }

    # if this is too high, perl quits(!!).  reports on mailing lists
    # don't seem to point to a universal answer.  5MB worked for some,
    # crashed for others.  1MB works for more people.  let's go with 1MB
    # for now.  :/
    my $req_bytes = $bytes > 1048576 ? 1048576 : $bytes;

    my $res = sysread($sock, $buf, $req_bytes, 0);
    DebugLevel >= 2 && $self->debugmsg("sysread = %d; \$! = %d", $res, $!);

    if (! $res && $! != EWOULDBLOCK) {
        # catches 0=conn closed or undef=error
        DebugLevel >= 2 && $self->debugmsg("Fd \#%d read hit the end of the road.", $self->{fd});
        return undef;
    }

    return \$buf;
}

=head2 (VIRTUAL) C<< $obj->event_read() >>

Readable event handler. Concrete deriviatives of Danga::Socket should
provide an implementation of this. The default implementation will die if
called.

=cut
sub event_read  { die "Base class event_read called for $_[0]\n"; }

=head2 (VIRTUAL) C<< $obj->event_err() >>

Error event handler. Concrete deriviatives of Danga::Socket should
provide an implementation of this. The default implementation will die if
called.

=cut
sub event_err   { die "Base class event_err called for $_[0]\n"; }

=head2 (VIRTUAL) C<< $obj->event_hup() >>

'Hangup' event handler. Concrete deriviatives of Danga::Socket should
provide an implementation of this. The default implementation will die if
called.

=cut
sub event_hup   { die "Base class event_hup called for $_[0]\n"; }

=head2 C<< $obj->event_write() >>

Writable event handler. Concrete deriviatives of Danga::Socket may wish to
provide an implementation of this. The default implementation calls
C<write()> with an C<undef>.

=cut
sub event_write {
    my $self = shift;
    $self->write(undef);
}

=head2 C<< $obj->watch_read( $boolean ) >>

Turn 'readable' event notification on or off.

=cut
sub watch_read {
    my Danga::Socket $self = shift;
    return if $self->{closed} || !$self->{sock};

    my $val = shift;
    my $event = $self->{event_watch};

    $event &= ~POLLIN if ! $val;
    $event |=  POLLIN if   $val;

    # If it changed, set it
    if ($event != $self->{event_watch}) {
        if ($HaveKQueue) {
            $KQueue->EV_SET($self->{fd}, IO::KQueue::EVFILT_READ(),
                            $val ? IO::KQueue::EV_ENABLE() : IO::KQueue::EV_DISABLE());
        }
        elsif ($HaveEpoll) {
            epoll_ctl($Epoll, EPOLL_CTL_MOD, $self->{fd}, $event)
                and $self->dump_error("couldn't modify epoll settings for $self->{fd} " .
                                      "from $self->{event_watch} -> $event: $! (" . ($!+0) . ")");
        }
        $self->{event_watch} = $event;
    }
}

=head2 C<< $obj->watch_write( $boolean ) >>

Turn 'writable' event notification on or off.

=cut
sub watch_write {
    my Danga::Socket $self = shift;
    return if $self->{closed} || !$self->{sock};

    my $val = shift;
    my $event = $self->{event_watch};

    $event &= ~POLLOUT if ! $val;
    $event |=  POLLOUT if   $val;

    if ($val && caller ne __PACKAGE__) {
        # A subclass registered interest, it's now responsible for this.
        $self->{write_set_watch} = 0;
    }

    # If it changed, set it
    if ($event != $self->{event_watch}) {
        if ($HaveKQueue) {
            $KQueue->EV_SET($self->{fd}, IO::KQueue::EVFILT_WRITE(),
                            $val ? IO::KQueue::EV_ENABLE() : IO::KQueue::EV_DISABLE());
        }
        elsif ($HaveEpoll) {
            epoll_ctl($Epoll, EPOLL_CTL_MOD, $self->{fd}, $event)
                and $self->dump_error("couldn't modify epoll settings for $self->{fd} " .
                                      "from $self->{event_watch} -> $event: $! (" . ($!+0) . ")");
        }
        $self->{event_watch} = $event;
    }
}

=head2 C<< $obj->dump_error( $message ) >>

Prints to STDERR a backtrace with information about this socket and what lead
up to the dump_error call.

=cut
sub dump_error {
    my $i = 0;
    my @list;
    while (my ($file, $line, $sub) = (caller($i++))[1..3]) {
        push @list, "\t$file:$line called $sub\n";
    }

    warn "ERROR: $_[1]\n" .
        "\t$_[0] = " . $_[0]->as_string . "\n" .
        join('', @list);
}

=head2 C<< $obj->debugmsg( $format, @args ) >>

Print the debugging message specified by the C<sprintf>-style I<format> and
I<args>.

=cut
sub debugmsg {
    my ( $self, $fmt, @args ) = @_;
    confess "Not an object" unless ref $self;

    chomp $fmt;
    printf STDERR ">>> $fmt\n", @args;
}


=head2 C<< $obj->peer_ip_string() >>

Returns the string describing the peer's IP

=cut
sub peer_ip_string {
    my Danga::Socket $self = shift;
    return _undef("peer_ip_string undef: no sock") unless $self->{sock};
    return $self->{peer_ip} if defined $self->{peer_ip};

    my $pn = getpeername($self->{sock});
    return _undef("peer_ip_string undef: getpeername") unless $pn;

    my ($port, $iaddr) = eval {
        if (length($pn) >= 28) {
            return Socket6::unpack_sockaddr_in6($pn);
        } else {
            return Socket::sockaddr_in($pn);
        }
    };

    if ($@) {
        $self->{peer_port} = "[Unknown peerport '$@']";
        return "[Unknown peername '$@']";
    }

    $self->{peer_port} = $port;

    if (length($iaddr) == 4) {
        return $self->{peer_ip} = Socket::inet_ntoa($iaddr);
    } else {
        $self->{peer_v6} = 1;
        return $self->{peer_ip} = Socket6::inet_ntop(Socket6::AF_INET6(),
                                                     $iaddr);
    }
}

=head2 C<< $obj->peer_addr_string() >>

Returns the string describing the peer for the socket which underlies this
object in form "ip:port"

=cut
sub peer_addr_string {
    my Danga::Socket $self = shift;
    my $ip = $self->peer_ip_string
        or return undef;
    return $self->{peer_v6} ?
        "[$ip]:$self->{peer_port}" :
        "$ip:$self->{peer_port}";
}

=head2 C<< $obj->local_ip_string() >>

Returns the string describing the local IP

=cut
sub local_ip_string {
    my Danga::Socket $self = shift;
    return _undef("local_ip_string undef: no sock") unless $self->{sock};
    return $self->{local_ip} if defined $self->{local_ip};

    my $pn = getsockname($self->{sock});
    return _undef("local_ip_string undef: getsockname") unless $pn;

    my ($port, $iaddr) = Socket::sockaddr_in($pn);
    $self->{local_port} = $port;

    return $self->{local_ip} = Socket::inet_ntoa($iaddr);
}

=head2 C<< $obj->local_addr_string() >>

Returns the string describing the local end of the socket which underlies this
object in form "ip:port"

=cut
sub local_addr_string {
    my Danga::Socket $self = shift;
    my $ip = $self->local_ip_string;
    return $ip ? "$ip:$self->{local_port}" : undef;
}


=head2 C<< $obj->as_string() >>

Returns a string describing this socket.

=cut
sub as_string {
    my Danga::Socket $self = shift;
    my $rw = "(" . ($self->{event_watch} & POLLIN ? 'R' : '') .
                   ($self->{event_watch} & POLLOUT ? 'W' : '') . ")";
    my $ret = ref($self) . "$rw: " . ($self->{closed} ? "closed" : "open");
    my $peer = $self->peer_addr_string;
    if ($peer) {
        $ret .= " to " . $self->peer_addr_string;
    }
    return $ret;
}

sub _undef {
    return undef unless $ENV{DS_DEBUG};
    my $msg = shift || "";
    warn "Danga::Socket: $msg\n";
    return undef;
}

package Danga::Socket::Timer;
# [$cancel_coderef];
sub cancel {
    $_[0][0]->();
}

=head1 AUTHORS

Brad Fitzpatrick <brad@danga.com> - author

Michael Granger <ged@danga.com> - docs, testing

Mark Smith <junior@danga.com> - contributor, heavy user, testing

Matt Sergeant <matt@sergeant.org> - kqueue support, docs, timers, other bits

=head1 BUGS

Not documented enough (but isn't that true of every project?).

tcp_cork only works on Linux for now.  No BSD push/nopush support.

=head1 LICENSE

License is granted to use and distribute this module under the same
terms as Perl itself.

=cut

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
