package Homelab::Mail;

use strict;
use warnings;
use IO::Socket::SSL;
use MIME::Base64 qw(encode_base64);

# Phase 1 of issue #015: talks to Dovecot directly over IMAP, using the
# caller's own homelab-api JWT as the IMAP credential via a hand-rolled
# AUTHENTICATE OAUTHBEARER exchange (Dovecot validates it by calling back
# into homelab-api's own GET /api/v1/auth/introspect) -- no IMAP password
# is ever stored here. See script/experiments/imap-oauthbearer-poc.pl and
# issue_tracking/015-dovecot-imap-api.md's "Progress notes" for how this
# was verified against production and the gotchas found along the way.
#
# Maintains one pooled IMAP connection per user per worker process (see
# _get_connection) so a frequently-polled endpoint like get_status doesn't
# open a fresh TCP+TLS+SASL handshake on every call. This pool is NOT
# shared across Mojolicious/hypnotoad worker processes -- see
# issue_tracking/015-dovecot-imap-api.md for that tradeoff.

sub new {
    my ($class, $db, $config) = @_;
    my $mail_cfg = $config->{mail} // {};
    my $imap_cfg = $mail_cfg->{imap} // {};
    my $pool_cfg = $mail_cfg->{pool} // {};

    my $self = {
        db   => $db,
        imap => {
            host            => $imap_cfg->{host} // 'imap.mailmasker.org',
            port            => $imap_cfg->{port} // 993,
            connect_timeout => $imap_cfg->{connect_timeout} // 10,
            command_timeout => $imap_cfg->{command_timeout} // 15,
        },
        pool_max_size     => $pool_cfg->{max_size} // 200,
        pool_idle_timeout => $pool_cfg->{idle_timeout} // 300,
        pool_max_lifetime => $pool_cfg->{max_lifetime} // 3300,
        pool              => {},
    };
    return bless $self, $class;
}

# --- Public API -------------------------------------------------------

sub get_status {
    my ($self, $email, $jwt) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;

    my $conn = $self->_get_connection($email, $jwt);
    return { error => $conn->{error} } if $conn->{error};

    my $result = $self->_imap_status($conn, 'INBOX');
    unless ($result) {
        # The pooled socket may have died server-side without us knowing.
        # Evict and reconnect exactly once, using THIS request's JWT (not
        # a stale cached one) -- Dovecot never re-checks the JWT mid
        # session, so a dead-socket reconnect is the only failure mode
        # that matters here.
        $self->_evict($email);
        $conn = $self->_get_connection($email, $jwt);
        return { error => $conn->{error} } if $conn->{error};
        $result = $self->_imap_status($conn, 'INBOX');
        return { error => 'IMAP STATUS command failed' } unless $result;
    }

    return { success => 1, unseen => $result->{unseen}, messages => $result->{messages} };
}

# --- Connection pool ----------------------------------------------------

sub _get_connection {
    my ($self, $email, $jwt) = @_;
    my $now = time();
    my $entry = $self->{pool}{$email};

    if ($entry) {
        if (($now - $entry->{last_used}) > $self->{pool_idle_timeout}
            || ($now - $entry->{connected_at}) > $self->{pool_max_lifetime}) {
            $self->_evict($email);
            $entry = undef;
        }
    }

    # Even a fresh-by-time-budget entry might already be dead server-side
    # (Dovecot's own idle timeout, a restart, a network blip) -- a cheap
    # NOOP is the only authoritative liveness check.
    if ($entry && !$self->_imap_noop($entry)) {
        $self->_evict($email);
        $entry = undef;
    }

    if (!$entry) {
        if (scalar(keys %{$self->{pool}}) >= $self->{pool_max_size}
            && !exists $self->{pool}{$email}) {
            $self->_evict_lru;
        }
        $entry = $self->_imap_connect($email, $jwt);
        return $entry if $entry->{error};
        $self->{pool}{$email} = $entry;
    }

    $entry->{last_used} = $now;
    return $entry;
}

sub _evict {
    my ($self, $email) = @_;
    my $conn = delete $self->{pool}{$email};
    return unless $conn;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(2);
        _imap_send($conn, _imap_next_tag($conn) . ' LOGOUT');
        alarm(0);
    };
    alarm(0);
    eval { $conn->{sock}->close };
}

sub _evict_lru {
    my ($self) = @_;
    my ($lru_email) = sort {
        $self->{pool}{$a}{last_used} <=> $self->{pool}{$b}{last_used}
    } keys %{$self->{pool}};
    return unless defined $lru_email;
    warn "Homelab::Mail: connection pool at max_size ($self->{pool_max_size}), "
        . "evicting least-recently-used entry for $lru_email\n";
    $self->_evict($lru_email);
}

# --- IMAP wire protocol ---------------------------------------------------

sub _with_timeout {
    my ($self, $timeout, $code) = @_;
    my $result;
    eval {
        local $SIG{ALRM} = sub { die "IMAP operation timed out after ${timeout}s\n" };
        alarm($timeout);
        $result = $code->();
        alarm(0);
    };
    my $err = $@;
    alarm(0);
    return ($result, $err || undef);
}

sub _imap_connect {
    my ($self, $email, $jwt) = @_;
    my ($conn, $err) = $self->_with_timeout($self->{imap}{connect_timeout}, sub {
        my $sock = IO::Socket::SSL->new(
            PeerHost => $self->{imap}{host},
            PeerPort => $self->{imap}{port},
        ) or die "connect to $self->{imap}{host}:$self->{imap}{port} failed: "
            . IO::Socket::SSL::errstr() . "\n";

        my $c = { sock => $sock, tagn => 0 };
        _imap_read_line($c); # server greeting, not needed beyond draining it

        my $tag = _imap_next_tag($c);
        my $sasl = "n,a=$email,\x01host=$self->{imap}{host}\x01port=$self->{imap}{port}"
            . "\x01auth=Bearer $jwt\x01\x01";
        _imap_send($c, "$tag AUTHENTICATE OAUTHBEARER " . encode_base64($sasl, ''));

        my $resp = _imap_read_line($c);
        if (defined $resp && $resp =~ /^\+/) {
            # SASL continuation -- for a failed OAUTHBEARER attempt this is
            # a base64 JSON error blob; RFC 7628 3.2.3 requires an empty
            # response to complete the failed exchange.
            _imap_send($c, '');
            $resp = _imap_read_line($c);
        }

        # On success Dovecot sends an untagged post-login CAPABILITY line
        # BEFORE the tagged OK -- keep reading until this attempt's own
        # tag shows up, don't assume the first line after AUTHENTICATE is it.
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_line($c);
        }
        die "AUTHENTICATE OAUTHBEARER failed for $email\n"
            unless defined $resp && $resp =~ /^\Q$tag\E OK/i;

        return $c;
    });

    return { error => "IMAP auth failed for $email: $err" } if $err;

    my $now = time();
    $conn->{connected_at} = $now;
    $conn->{last_used}    = $now;
    return $conn;
}

sub _imap_status {
    my ($self, $conn, $mailbox) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag STATUS $mailbox (MESSAGES UNSEEN)");

        my ($messages, $unseen);
        my $resp = _imap_read_line($conn);
        while (defined $resp) {
            if ($resp =~ /^\*\s+STATUS\s+\S+\s+\(([^)]*)\)/i) {
                my $attrs = $1;
                ($messages) = $attrs =~ /MESSAGES\s+(\d+)/i;
                ($unseen)   = $attrs =~ /UNSEEN\s+(\d+)/i;
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_line($conn);
        }
        die "STATUS command failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        die "STATUS response missing MESSAGES/UNSEEN\n"
            unless defined $messages && defined $unseen;

        return { messages => $messages + 0, unseen => $unseen + 0 };
    });
    return undef if $err;
    return $result;
}

sub _imap_noop {
    my ($self, $conn) = @_;
    my (undef, $err) = $self->_with_timeout(5, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag NOOP");
        my $resp = _imap_read_line($conn);
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_line($conn);
        }
        die "NOOP failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return 1;
    });
    return $err ? 0 : 1;
}

sub _imap_read_line {
    my ($conn) = @_;
    my $line = $conn->{sock}->getline;
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    return $line;
}

sub _imap_send {
    my ($conn, $line) = @_;
    $conn->{sock}->print("$line\r\n");
}

sub _imap_next_tag {
    my ($conn) = @_;
    return 'a' . ++$conn->{tagn};
}

1;
