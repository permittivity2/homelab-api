package Homelab::Mail;

use strict;
use warnings;
use IO::Socket::SSL;
use MIME::Base64 qw(encode_base64 decode_base64);
use MIME::QuotedPrint qw(decode_qp);
use Encode qw();
use Encode::MIME::Header;
use DateTime;

# Phase 1/2 of issue #015: talks to Dovecot directly over IMAP, using the
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
#
# Phase 2 adds folder/message listing and message/part fetching. Design
# principle: this module never decides which part of a message is "the"
# body or auto-renders anything -- get_message returns pure structure
# (headers + a flat list of MIME parts), and get_part fetches any one
# part's raw decoded bytes by its part number, uniformly whether that part
# is text/plain, text/html, or a binary attachment. Deciding what to
# render is the caller's job.

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

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $status = $self->_imap_status($conn, 'INBOX');
        die "IMAP STATUS command failed\n" unless $status;
        return $status;
    });
    return { error => $err } if $err;
    return { success => 1, unseen => $result->{unseen}, messages => $result->{messages} };
}

sub list_folders {
    my ($self, $email, $jwt) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;

    my ($folders, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $f = $self->_imap_list($conn);
        die "IMAP LIST command failed\n" unless $f;
        return $f;
    });
    return { error => $err } if $err;
    return { success => 1, folders => $folders };
}

# Pagination is a sequence-number range computed from EXISTS at request
# time, not a UID cursor -- this is an interactive browse view for a
# single-user mailbox, not a durable feed, so this keeps pagination
# consistent with the rest of this API's existing idiom (e.g.
# drive file-info --startat). Known, accepted caveat: since sequence
# numbers are positions within the mailbox at the moment of SELECT, the
# window can shift slightly if mail arrives/is expunged between two
# successive calls.
sub list_messages {
    my ($self, $email, $jwt, $folder, $offset, $limit) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    $folder = 'INBOX' unless defined $folder && length $folder;
    $offset = 0  unless defined $offset && $offset =~ /^\d+$/;
    $limit  = 50 unless defined $limit && $limit =~ /^\d+$/ && $limit > 0;
    $limit  = 200 if $limit > 200;

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $folder);
        die $sel->{error} if $sel->{error};

        my $total  = $sel->{exists};
        my $seq_hi = $total - $offset;
        return { total => $total, messages => [] } if $seq_hi < 1;
        my $seq_lo = $seq_hi - $limit + 1;
        $seq_lo = 1 if $seq_lo < 1;

        my $messages = $self->_imap_fetch_headers($conn, "$seq_lo:$seq_hi");
        die "IMAP FETCH command failed\n" unless $messages;

        # IMAP returns ascending sequence order (oldest of the range
        # first) -- reverse for newest-first.
        return { total => $total, messages => [ reverse @$messages ] };
    });
    return { error => $err } if $err;
    return { success => 1, folder => $folder, offset => $offset, limit => $limit, %$result };
}

# Purely structural -- no part content is fetched or decoded here. Returns
# headers (from ENVELOPE) and a flat list of every MIME part (from
# BODYSTRUCTURE), text and binary alike. Fetch a specific part's content
# via get_part().
sub get_message {
    my ($self, $email, $jwt, $folder, $uid) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder or uid' } unless $folder && $uid;

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $folder);
        die $sel->{error} if $sel->{error};

        my $item = $self->_imap_uid_fetch($conn, $uid, 'FLAGS ENVELOPE BODYSTRUCTURE');
        die "IMAP FETCH command failed\n" unless $item;
        die "Message not found: UID $uid\n" unless %$item;

        return {
            success => 1,
            uid     => $uid + 0,
            flags   => $item->{FLAGS} || [],
            headers => _envelope_to_hash($item->{ENVELOPE}),
            parts   => _bodystructure_to_parts($item->{BODYSTRUCTURE}),
        };
    });
    return { error => $err } if $err;
    return $result;
}

# Fetches one part's raw decoded content by part number -- works
# identically whether that part is text/plain, text/html, or a binary
# attachment; there is no separate "attachment" method. Re-derives the
# part's content-type/charset/filename from a fresh BODYSTRUCTURE fetch
# rather than trusting a client-supplied part id blindly (this also
# validates the part actually exists on this message).
sub get_part {
    my ($self, $email, $jwt, $folder, $uid, $part) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder, uid, or part' } unless $folder && $uid && defined $part && length $part;
    return { error => 'Invalid part number' } unless $part =~ /^\d+(?:\.\d+)*$/;

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $folder);
        die $sel->{error} if $sel->{error};

        my $item = $self->_imap_uid_fetch($conn, $uid, 'BODYSTRUCTURE');
        die "IMAP FETCH command failed\n" unless $item;
        die "Message not found: UID $uid\n" unless %$item;

        my $parts = _bodystructure_to_parts($item->{BODYSTRUCTURE});
        my ($meta) = grep { $_->{part_number} eq $part } @$parts;
        die "Part not found: $part\n" unless $meta;

        my $raw = $self->_imap_uid_fetch_body_part($conn, $uid, $part);
        die "IMAP FETCH command failed\n" unless defined $raw;

        my $bytes = _decode_part_content($raw, $meta->{encoding});
        my $content_type = $meta->{content_type};
        $content_type .= "; charset=$meta->{charset}" if defined $meta->{charset};

        return {
            success      => 1,
            content_type => $content_type,
            filename     => $meta->{filename},
            size         => length($bytes),
            data         => $bytes,
        };
    });
    return { error => $err } if $err;
    return $result;
}

# --- Connection pool ----------------------------------------------------

# Runs $code->($conn) using a pooled connection for ($email, $jwt). If
# $code dies, evicts the connection and retries exactly once with a
# freshly authenticated connection using the CURRENT request's JWT (never
# a stale cached one) before giving up -- the shared "the pooled socket
# might have silently died" recovery pattern used by every IMAP-issuing
# method above. Returns ($value, undef) on success or (undef, $error) on
# failure, where $error is the die message from the last attempt (e.g.
# "Folder not found: ..." from _imap_select, propagated through so routes
# can distinguish a bad folder/UID from a generic downstream failure).
sub _with_connection {
    my ($self, $email, $jwt, $code) = @_;
    my $conn = $self->_get_connection($email, $jwt);
    return (undef, $conn->{error}) if $conn->{error};

    my $result = eval { $code->($conn) };
    my $err = $@;
    if (!$result) {
        $self->_evict($email);
        $conn = $self->_get_connection($email, $jwt);
        return (undef, $conn->{error}) if $conn->{error};
        $result = eval { $code->($conn) };
        $err = $@;
        return (undef, $err || 'IMAP command failed') unless $result;
    }
    return ($result, undef);
}

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
        _imap_read_response_line($c); # server greeting, not needed beyond draining it

        my $tag = _imap_next_tag($c);
        my $sasl = "n,a=$email,\x01host=$self->{imap}{host}\x01port=$self->{imap}{port}"
            . "\x01auth=Bearer $jwt\x01\x01";
        _imap_send($c, "$tag AUTHENTICATE OAUTHBEARER " . encode_base64($sasl, ''));

        my $resp = _imap_read_response_line($c);
        if (defined $resp && $resp =~ /^\+/) {
            # SASL continuation -- for a failed OAUTHBEARER attempt this is
            # a base64 JSON error blob; RFC 7628 3.2.3 requires an empty
            # response to complete the failed exchange.
            _imap_send($c, '');
            $resp = _imap_read_response_line($c);
        }

        # On success Dovecot sends an untagged post-login CAPABILITY line
        # BEFORE the tagged OK -- keep reading until this attempt's own
        # tag shows up, don't assume the first line after AUTHENTICATE is it.
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_response_line($c);
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
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            if ($resp =~ /^\*\s+STATUS\s+\S+\s+\(([^)]*)\)/i) {
                my $attrs = $1;
                ($messages) = $attrs =~ /MESSAGES\s+(\d+)/i;
                ($unseen)   = $attrs =~ /UNSEEN\s+(\d+)/i;
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
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
        my $resp = _imap_read_response_line($conn);
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_response_line($conn);
        }
        die "NOOP failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return 1;
    });
    return $err ? 0 : 1;
}

# Ensures $conn has $folder currently selected (SELECT, not EXAMINE --
# SELECT alone doesn't mutate anything; only a non-.PEEK FETCH or an
# explicit STORE would, and this module issues neither -- using SELECT
# uniformly now avoids a connection-state fork if a later phase adds
# flag-setting to the same pooled connection). No-ops if $folder is
# already selected on this connection. Returns {exists=>N} on success or
# {error=>"Folder not found: ..."} (or a generic transport-failure
# message) on failure -- never dies to its own caller.
sub _imap_select {
    my ($self, $conn, $folder) = @_;
    if (defined $conn->{selected_mailbox} && $conn->{selected_mailbox} eq $folder) {
        return { exists => $conn->{selected_exists} };
    }
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag SELECT " . _imap_quote($folder));
        my $exists;
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            ($exists) = $resp =~ /^\*\s+(\d+)\s+EXISTS/i if !defined $exists;
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
        }
        die "Folder not found: $folder\n"
            if defined $resp && $resp =~ /^\Q$tag\E\s+(NO|BAD)/i;
        die "SELECT failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return { exists => $exists // 0 };
    });
    return { error => $err } if $err;
    $conn->{selected_mailbox} = $folder;
    $conn->{selected_exists}  = $result->{exists};
    return $result;
}

sub _imap_list {
    my ($self, $conn) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, qq{$tag LIST "" "*" RETURN (SPECIAL-USE)});
        my @folders;
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            if ($resp =~ /^\*\s+LIST\s+\((.*?)\)\s+(NIL|"(?:[^"\\]|\\.)*"|\S+)\s+(.*)$/is) {
                my ($flags_str, $delim_tok, $name_tok) = ($1, $2, $3);
                my @flags = $flags_str =~ /(\\\S+)/g;
                my ($delim) = _imap_parse_token($delim_tok, 0);
                my ($name)  = _imap_parse_token($name_tok, 0);
                push @folders, {
                    name        => $name,
                    delimiter   => $delim,
                    flags       => \@flags,
                    special_use => [ grep { /^\\(Sent|Trash|Drafts|Archive|Junk|All)$/i } @flags ],
                };
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
        }
        die "LIST failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return \@folders;
    });
    return undef if $err;
    return $result;
}

sub _imap_fetch_headers {
    my ($self, $conn, $seq_range) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag FETCH $seq_range (UID FLAGS ENVELOPE RFC822.SIZE)");
        my @messages;
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            if ($resp =~ /^\*\s+\d+\s+FETCH\s+\((.*)\)\s*$/is) {
                my $items = _imap_parse_fetch_items($1);
                my $env   = _envelope_to_hash($items->{ENVELOPE});
                push @messages, {
                    uid     => ($items->{UID} // 0) + 0,
                    flags   => $items->{FLAGS} || [],
                    subject => $env->{subject},
                    from    => $env->{from},
                    date    => $env->{date},
                    size    => ($items->{'RFC822.SIZE'} // 0) + 0,
                };
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
        }
        die "FETCH failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return \@messages;
    });
    return undef if $err;
    return $result;
}

# Fetches ENVELOPE/BODYSTRUCTURE/etc for one message by UID. Returns a
# hashref of uppercased item name -> parsed value (see
# _imap_parse_fetch_items), or an EMPTY hashref (not undef) if the UID
# genuinely doesn't exist in this mailbox -- callers distinguish
# "not found" (truthy empty hashref) from "IMAP-level error" (undef).
sub _imap_uid_fetch {
    my ($self, $conn, $uid, $items_str) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag UID FETCH $uid ($items_str)");
        my %items;
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            if ($resp =~ /^\*\s+\d+\s+FETCH\s+\((.*)\)\s*$/is) {
                %items = %{ _imap_parse_fetch_items($1) };
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
        }
        die "UID FETCH failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return \%items;
    });
    return undef if $err;
    return $result;
}

sub _imap_uid_fetch_body_part {
    my ($self, $conn, $uid, $part) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag UID FETCH $uid (BODY.PEEK[$part])");
        my $data;
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            if ($resp =~ /^\*\s+\d+\s+FETCH\s+\((.*)\)\s*$/is) {
                my $items = _imap_parse_fetch_items($1);
                for my $key (keys %$items) {
                    if ($key =~ /^BODY\[/i) {
                        $data = $items->{$key};
                        last;
                    }
                }
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
        }
        die "UID FETCH failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return defined $data ? $data : '';
    });
    return undef if $err;
    return $result;
}

# --- ENVELOPE / BODYSTRUCTURE parsing -------------------------------------

# RFC 3501 7.4.2: ENVELOPE's 10 fixed fields, in order.
sub _envelope_to_hash {
    my ($env) = @_;
    return {} unless $env && ref $env eq 'ARRAY';
    my ($date, $subject, $from, $sender, $reply_to, $to, $cc, $bcc, $in_reply_to, $message_id) = @$env;
    return {
        date        => _parse_imap_date($date),
        subject     => _decode_mime_header($subject),
        from        => _addr_list_to_hash($from),
        to          => _addr_list_to_hash($to),
        cc          => _addr_list_to_hash($cc),
        reply_to    => _addr_list_to_hash($reply_to),
        message_id  => $message_id,
        in_reply_to => $in_reply_to,
    };
}

# ((name adl mailbox host) ...) -> [ {name, email}, ... ] (undef/NIL -> [])
sub _addr_list_to_hash {
    my ($list) = @_;
    return [] unless $list && ref $list eq 'ARRAY';
    return [ map {
        my ($name, undef, $mailbox, $host) = @$_;
        {
            name  => _decode_mime_header($name),
            email => (defined $mailbox && defined $host) ? "$mailbox\@$host" : undef,
        };
    } @$list ];
}

sub _decode_mime_header {
    my ($str) = @_;
    return undef unless defined $str;
    my $decoded = eval { Encode::decode('MIME-Header', $str) };
    return defined $decoded ? $decoded : $str;
}

my @MONTHS     = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my %MONTH_NUM  = map { $MONTHS[$_] => $_ + 1 } 0 .. $#MONTHS;

# Hand-rolled RFC 5322-ish date parsing (day-of-week and seconds are
# optional per real-world variance) into an ISO8601 UTC string -- avoids
# adding a new CPAN date-parsing dependency; DateTime itself is already a
# dependency. Returns undef (not fatal) on anything unparseable, since a
# malformed Date header on one message must not break listing/fetching it.
sub _parse_imap_date {
    my ($str) = @_;
    return undef unless defined $str;
    return undef unless $str =~ /(\d{1,2})\s+(\w{3})\w*\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4})?/;
    my ($day, $mon, $year, $h, $m, $s, $tz) = ($1, $2, $3, $4, $5, $6 // 0, $7 // '+0000');
    my $month = $MONTH_NUM{ucfirst(lc($mon))};
    return undef unless $month;

    my $dt = eval {
        DateTime->new(year => $year, month => $month, day => $day,
                       hour => $h, minute => $m, second => $s,
                       time_zone => 'UTC');
    };
    return undef unless $dt;

    if ($tz =~ /^([+-])(\d{2})(\d{2})$/) {
        my $offset_minutes = ($2 * 60 + $3) * ($1 eq '-' ? 1 : -1);
        $dt->add(minutes => $offset_minutes);
    }
    return $dt->strftime('%Y-%m-%dT%H:%M:%SZ');
}

# Walks a (possibly multipart-nested) BODYSTRUCTURE into a flat list of
# every part -- text and binary alike, no filtering, no "is this an
# attachment" judgment made here. RFC 3501 6.4.5 dot-notation part
# numbering: "1", "2", ... at the top level; a part nested inside
# multipart part "1" is "1.1", "1.2", ...; a single-part (non-multipart)
# message's one part is addressed as "1".
#
# Explicitly out of scope: message/rfc822 nested messages are returned as
# one opaque part (content_type "message/rfc822"), not recursively
# expanded into their own inner parts. multipart/signed or
# multipart/encrypted messages are untested against production -- the
# walker still enumerates their parts generically, which should degrade
# reasonably (a signature shown as a generic part) but hasn't been
# verified against a real signed message.
sub _bodystructure_to_parts {
    my ($bs) = @_;
    my @parts;
    _walk_bodystructure($bs, '', \@parts);
    return \@parts;
}

sub _walk_bodystructure {
    my ($node, $prefix, $out) = @_;
    return unless ref $node eq 'ARRAY';

    my @subparts;
    my $i = 0;
    while ($i < @$node && ref $node->[$i] eq 'ARRAY') {
        push @subparts, $node->[$i];
        $i++;
    }

    if (@subparts) {
        # Leading elements were sub-parts, so this node is a
        # multipart/<subtype> -- the subtype string itself (at $node->[$i])
        # isn't needed for our part list, only its children are.
        my $n = 0;
        for my $sp (@subparts) {
            $n++;
            my $part_num = $prefix eq '' ? "$n" : "$prefix.$n";
            _walk_bodystructure($sp, $part_num, $out);
        }
        return;
    }

    # Leaf part: (type subtype (params) cid description encoding size ...extension-fields)
    my ($type, $subtype, $params, undef, undef, $encoding, $size, @rest) = @$node;
    return unless defined $type;
    my $content_type = lc("$type/$subtype");

    my %params_hash;
    if (ref $params eq 'ARRAY') {
        for (my $j = 0; $j + 1 < @$params; $j += 2) {
            $params_hash{lc($params->[$j] // '')} = $params->[$j + 1];
        }
    }
    my $part_number = $prefix eq '' ? '1' : $prefix;
    my $filename    = $params_hash{name};

    # Extended BODYSTRUCTURE form appends body-fld-dsp = NIL |
    # ("disposition-type" (param-pairs)) among the trailing extension
    # fields -- scan for it rather than assuming a fixed position, since
    # not every server sends every optional extension field.
    my $disposition;
    for my $extra (@rest) {
        next unless ref $extra eq 'ARRAY' && @$extra >= 1 && defined $extra->[0] && !ref $extra->[0];
        my ($dtype, $dparams) = @$extra;
        next unless $dtype =~ /^(?:inline|attachment)$/i;
        $disposition = lc($dtype);
        if (ref $dparams eq 'ARRAY') {
            for (my $j = 0; $j + 1 < @$dparams; $j += 2) {
                $filename = $dparams->[$j + 1] if lc($dparams->[$j] // '') eq 'filename';
            }
        }
        last;
    }
    $disposition //= (lc($content_type) =~ m{^text/(?:plain|html)$} && !$filename) ? 'inline' : 'attachment';

    push @$out, {
        part_number  => $part_number,
        content_type => $content_type,
        charset      => $params_hash{charset},
        filename     => _decode_mime_header($filename),
        size         => $size,
        encoding     => lc($encoding // '7bit'),
        disposition  => $disposition,
    };
}

# Undoes only the declared Content-Transfer-Encoding -- no charset
# transcoding happens here. Per this module's "let the caller decide"
# principle, callers get the part's real bytes as-is (in whatever charset
# the message declares), named in the response's Content-Type header, and
# it's up to the caller to interpret/render them.
sub _decode_part_content {
    my ($raw, $encoding) = @_;
    return '' unless defined $raw;
    $encoding = lc($encoding // '7bit');
    return decode_base64($raw) if $encoding eq 'base64';
    return decode_qp($raw)     if $encoding eq 'quoted-printable';
    return $raw;
}

# --- Generic IMAP response tokenizer ---------------------------------------
#
# One parser, used for both ENVELOPE and BODYSTRUCTURE (and reusable for
# any other IMAP parenthesized-list data), since both use the same
# underlying "list" syntax: atoms, "quoted strings", {n} literals (already
# resolved into a synthetic \x00LIT\x00<n>\x00<bytes>\x00 token by
# _imap_read_response_line below), NIL, and (...) nested lists.

# Parses one token starting at $pos in $str. Returns ($value, $new_pos).
sub _imap_parse_token {
    my ($str, $pos) = @_;
    $pos = 0 unless defined $pos;
    $pos++ while $pos < length($str) && substr($str, $pos, 1) eq ' ';
    return (undef, $pos) if $pos >= length($str);

    my $c = substr($str, $pos, 1);

    return _imap_parse_paren_list($str, $pos) if $c eq '(';

    if ($c eq '"') {
        my $i = $pos + 1;
        my $out = '';
        while ($i < length($str)) {
            my $ch = substr($str, $i, 1);
            if ($ch eq '\\') {
                $out .= substr($str, $i + 1, 1);
                $i += 2;
            } elsif ($ch eq '"') {
                $i++;
                last;
            } else {
                $out .= $ch;
                $i++;
            }
        }
        return ($out, $i);
    }

    if ($c eq "\x00") {
        if (substr($str, $pos, 5) eq "\x00LIT\x00" && substr($str, $pos + 5) =~ /^(\d+)\x00/) {
            my $n = $1;
            my $data_start = $pos + 5 + length($1) + 1;
            my $data = substr($str, $data_start, $n);
            return ($data, $data_start + $n + 1); # +1 skips the trailing sentinel NUL
        }
        return (undef, $pos + 1); # unrecognized NUL -- shouldn't happen, skip it
    }

    my $start = $pos;
    while ($pos < length($str)) {
        my $ch = substr($str, $pos, 1);
        last if $ch eq ' ' || $ch eq '(' || $ch eq ')' || $ch eq "\x00";
        $pos++;
    }
    my $atom = substr($str, $start, $pos - $start);
    return (undef, $pos) if uc($atom) eq 'NIL';
    return ($atom, $pos);
}

# Parses one full "(...)" list starting at $str's $pos (must be '(').
# Returns (\@items, $pos_after_close_paren).
sub _imap_parse_paren_list {
    my ($str, $pos) = @_;
    return (undef, $pos) unless substr($str, $pos, 1) eq '(';
    $pos++;
    my @items;
    while (1) {
        $pos++ while $pos < length($str) && substr($str, $pos, 1) eq ' ';
        last if $pos >= length($str) || substr($str, $pos, 1) eq ')';
        my ($val, $new_pos) = _imap_parse_token($str, $pos);
        push @items, $val;
        $pos = $new_pos;
    }
    $pos++ if $pos < length($str) && substr($str, $pos, 1) eq ')';
    return (\@items, $pos);
}

# Parses the space-separated "NAME value NAME value ..." sequence found
# inside a "* n FETCH (...)" response's parens into a hash keyed by
# uppercased item name (e.g. UID, FLAGS, ENVELOPE, BODYSTRUCTURE,
# 'RFC822.SIZE', 'BODY[1]'). FLAGS' value is left as the arrayref
# _imap_parse_token already produces for a parenthesized list.
sub _imap_parse_fetch_items {
    my ($str) = @_;
    my %items;
    my $pos = 0;
    while (1) {
        $pos++ while $pos < length($str) && substr($str, $pos, 1) eq ' ';
        last if $pos >= length($str);
        my ($name, $p1) = _imap_parse_token($str, $pos);
        last unless defined $name;
        $pos = $p1;
        $pos++ while $pos < length($str) && substr($str, $pos, 1) eq ' ';
        my ($value, $p2) = _imap_parse_token($str, $pos);
        $pos = $p2;
        $items{uc($name)} = $value;
    }
    return \%items;
}

sub _imap_quote {
    my ($str) = @_;
    $str =~ s/([\\"])/\\$1/g;
    return qq{"$str"};
}

# Reads one full logical IMAP response line, resolving any {n} literals
# found in it by reading exactly n raw bytes off the socket and splicing
# them into the returned line as a synthetic literal token
# "\x00LIT\x00<n>\x00<n raw bytes>\x00" (NUL is illegal in IMAP literal
# data per RFC 3501, so it's a safe sentinel) so _imap_parse_token can
# recognize literal boundaries without being confused by stray CRLFs,
# quotes, or backslashes inside the literal's own bytes.
sub _imap_read_response_line {
    my ($conn) = @_;
    my $line = _imap_read_line($conn);
    return undef unless defined $line;

    while ($line =~ /\{(\d+)\+?\}\z/) {
        my $n = $1;
        my $data = '';
        while (length($data) < $n) {
            my $chunk;
            my $got = $conn->{sock}->read($chunk, $n - length($data));
            die "IMAP literal read failed (wanted $n bytes)\n" unless defined $got && $got > 0;
            $data .= $chunk;
        }
        # The bytes after the literal continue the SAME logical response
        # (e.g. a closing ")" for a FETCH list) -- read and append that
        # continuation, since getline() would otherwise treat any CRLF
        # embedded in $data as a line break.
        my $rest = $conn->{sock}->getline;
        die "IMAP literal not followed by continuation data\n" unless defined $rest;
        $rest =~ s/\r?\n\z//;
        $line =~ s/\{\d+\+?\}\z//;
        $line .= "\x00LIT\x00" . length($data) . "\x00" . $data . "\x00" . $rest;
    }
    return $line;
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
