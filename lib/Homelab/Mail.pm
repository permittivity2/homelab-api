package Homelab::Mail;

use strict;
use warnings;
use IO::Socket::SSL;
use MIME::Base64 qw(encode_base64 decode_base64);
use MIME::QuotedPrint qw(decode_qp);
use Encode qw();
use Encode::MIME::Header;
use DateTime;
use Crypt::URandom qw(urandom);

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
#
# Phase 4 adds outbound mail: send_message/save_draft construct a MIME
# message and either transmit it over SMTP (hand-rolled AUTH OAUTHBEARER/
# XOAUTH2 over IO::Socket::SSL, same low-dependency style as IMAP --
# confirmed working against production in
# script/experiments/smtp-oauthbearer-poc.pl, see issue_tracking's
# Progress notes) or APPEND it to the Drafts folder. list_allowed_senders
# is a pure DB read (no IMAP/SMTP) surfacing which From addresses/domains
# Postfix's own sender-login-map already authorizes the caller to use --
# this module is not re-implementing that enforcement, only displaying it,
# and independently re-checks it before ever opening an SMTP connection.

sub new {
    my ($class, $db, $config) = @_;
    my $mail_cfg = $config->{mail} // {};
    my $imap_cfg = $mail_cfg->{imap} // {};
    my $pool_cfg = $mail_cfg->{pool} // {};

    # No default host/port: which mail server this talks to is inherently
    # environment-specific (a different deployment could point at a
    # completely different server), so config.yml MUST say explicitly --
    # fail fast at startup rather than silently guessing.
    my $host = $imap_cfg->{host}
        or die "Homelab::Mail: mail.imap.host is required in config.yml\n";
    my $port = $imap_cfg->{port}
        or die "Homelab::Mail: mail.imap.port is required in config.yml\n";

    # Same rule for SMTP (Phase 4): no default -- which mail server this
    # sends outbound through is just as environment-specific as IMAP.
    my $smtp_cfg  = $mail_cfg->{smtp} // {};
    my $smtp_host = $smtp_cfg->{host}
        or die "Homelab::Mail: mail.smtp.host is required in config.yml\n";
    my $smtp_port = $smtp_cfg->{port}
        or die "Homelab::Mail: mail.smtp.port is required in config.yml\n";

    my $self = {
        db   => $db,
        imap => {
            host            => $host,
            port            => $port,
            connect_timeout => $imap_cfg->{connect_timeout} // 10,
            command_timeout => $imap_cfg->{command_timeout} // 15,
        },
        smtp => {
            host            => $smtp_host,
            port            => $smtp_port,
            connect_timeout => $smtp_cfg->{connect_timeout} // 10,
            command_timeout => $smtp_cfg->{command_timeout} // 15,
            data_timeout    => $smtp_cfg->{data_timeout} // 30,
        },
        max_message_size_mb => $mail_cfg->{max_message_size_mb} // 25,
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
#
# Also returns the raw, unparsed RFC 5322 header block (everything before
# the blank line separating headers from body) via BODY.PEEK[HEADER],
# always base64-encoded in rawheaderb64. Headers are supposed to be 7-bit
# ASCII per RFC 5322, but plenty of real-world mail is non-compliant and
# stuffs raw 8-bit bytes into header values instead of properly RFC
# 2047-encoding them -- base64 sidesteps that entirely (no JSON-encoding
# risk from an invalid byte sequence, no need to guess a charset), at the
# small cost of the caller needing to base64-decode it.
sub get_message {
    my ($self, $email, $jwt, $folder, $uid) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder or uid' } unless $folder && $uid;

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $folder);
        die $sel->{error} if $sel->{error};

        my $item = $self->_imap_uid_fetch($conn, $uid, 'FLAGS ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER]');
        die "IMAP FETCH command failed\n" unless $item;
        die "Message not found: UID $uid\n" unless %$item;

        my $raw_bytes = $item->{'BODY[HEADER]'};

        return {
            success      => 1,
            uid          => $uid + 0,
            flags        => $item->{FLAGS} || [],
            headers      => _envelope_to_hash($item->{ENVELOPE}),
            rawheaderb64 => defined $raw_bytes ? encode_base64($raw_bytes, '') : undef,
            parts        => _bodystructure_to_parts($item->{BODYSTRUCTURE}),
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

# Phase 4: outbound mail. send_message/save_draft share MIME-construction
# logic (_build_mime_message et al, below) and never guess/pick anything
# on the caller's behalf -- the From address is independently re-verified
# against list_allowed_senders before any SMTP connection opens, and
# recipients/attachments are exactly what the caller specified.

# Lists which From addresses/domains the caller is authorized to send as,
# per dovecot.allowed_sender_addresses (a view already encoding Postfix's
# full smtpd_sender_login_maps authorization logic). Pure DB read, no
# IMAP/SMTP involved. This is advisory/display data for the caller --
# Postfix remains the actual enforcement point at send time, and
# _from_address_authorized independently re-checks this same data before
# _build_mime_message will ever let a message proceed to SMTP.
sub list_allowed_senders {
    my ($self, $email) = @_;
    return { error => 'Missing email' } unless $email;
    my $rows = eval {
        $self->{db}->query_rows(
            'SELECT sender_address FROM dovecot.allowed_sender_addresses WHERE sasl_username = ?',
            $email
        );
    };
    return { error => 'Failed to query allowed sender addresses' } if $@ || !defined $rows;

    my (@addresses, @domains);
    for my $r (@$rows) {
        my $addr = $r->{sender_address};
        next unless defined $addr;
        if ($addr =~ /^%\@(.+)$/) {
            push @domains, "\@$1";
        } else {
            push @addresses, $addr;
        }
    }
    return { success => 1, addresses => \@addresses, domains => \@domains };
}

# Fails CLOSED: if list_allowed_senders itself errors (DB problem), this
# returns false -- never "assume authorized." Called from
# _build_mime_message, strictly before any SMTP socket is opened, so a
# rejected From address never reaches the wire at all.
sub _from_address_authorized {
    my ($self, $email, $from) = @_;
    my $allowed = $self->list_allowed_senders($email);
    return 0 if $allowed->{error};
    my ($from_addr) = $from =~ /<([^>]+)>/ ? ($1) : ($from);
    return 1 if grep { lc($_) eq lc($from_addr) } @{ $allowed->{addresses} };
    my ($domain) = $from_addr =~ /\@(.+)$/;
    return 0 unless $domain;
    return 1 if grep { lc($_) eq '@' . lc($domain) } @{ $allowed->{domains} };
    return 0;
}

# Sends a composed message over SMTP (hand-rolled AUTH OAUTHBEARER, falling
# back to AUTH XOAUTH2 -- both confirmed working against production, see
# script/experiments/smtp-oauthbearer-poc.pl and issue_tracking's Progress
# notes; OAUTHBEARER succeeded on the very first attempt there). $message:
# {from, to=>[...], cc=>[...], bcc=>[...], subject, text_body, html_body,
#  in_reply_to=>{folder,uid} | "<raw Message-ID>", attachments=>[{filename,
#  content_type, bytes}, ...]}. No SMTP connection pool (see
# _with_smtp_connection) -- sending is comparatively rare and stateless
# per transaction, unlike IMAP's frequently-polled, SELECT-stateful use.
sub send_message {
    my ($self, $email, $jwt, $message) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    $message = {} unless ref $message eq 'HASH';

    if ($message->{in_reply_to}) {
        my ($msg_id, $refs) = eval { $self->_resolve_reply_headers($email, $jwt, $message->{in_reply_to}) };
        if ($@) { (my $m = $@) =~ s/\n$//; return { error => $m }; }
        $message->{in_reply_to_message_id} = $msg_id;
        $message->{references} = $refs;
    }

    my ($raw, $message_id) = eval { $self->_build_mime_message($email, $message) };
    if ($@) { (my $m = $@) =~ s/\n$//; return { error => $m }; }

    my @rcpts = (@{ $message->{to} || [] }, @{ $message->{cc} || [] }, @{ $message->{bcc} || [] });
    return { error => 'No recipients' } unless @rcpts;

    my ($ok, $smtp_err) = $self->_with_smtp_connection($email, $jwt, sub {
        my ($conn) = @_;
        my ($mf_code) = $self->_smtp_command($conn, "MAIL FROM:<$message->{from}>");
        die "From address rejected by mail server\n" unless defined $mf_code && $mf_code eq '250';
        for my $rcpt (@rcpts) {
            my ($rc_code) = $self->_smtp_command($conn, "RCPT TO:<$rcpt>");
            die "Recipient rejected by mail server: $rcpt\n" unless defined $rc_code && $rc_code eq '250';
        }
        my $r = $self->_smtp_send_data($conn, $raw);
        die "SMTP DATA command failed\n" unless $r;
        return 1;
    });
    return { error => $smtp_err } if $smtp_err;

    # Best-effort Sent-copy filing. The message has already irreversibly
    # left via SMTP at this point -- failing the whole call over a
    # missing/ambiguous Sent folder would misleadingly suggest the send
    # itself failed, risking a well-meaning caller retry that double-sends
    # the same email to a real recipient. Report as a warning instead.
    my ($sent_folder, $serr) = $self->_resolve_special_folder($email, $jwt, '\Sent');
    my $warning;
    if ($serr) {
        $warning = "Message sent, but could not file a Sent copy: $serr";
    } else {
        my (undef, $aerr) = $self->_with_connection($email, $jwt, sub {
            my ($conn) = @_;
            my $r = $self->_imap_append($conn, $sent_folder, $raw, ['\Seen']);
            die "IMAP APPEND to Sent failed\n" unless $r;
            return 1;
        });
        $warning = "Message sent, but could not file a Sent copy: $aerr" if $aerr;
    }

    return { success => 1, message_id => $message_id, ($warning ? (warning => $warning) : ()) };
}

# Builds the identical MIME message send_message would, but APPENDs it to
# the resolved Drafts folder instead of transmitting -- a draft may be
# incomplete (no recipients yet), but the From-authorization check still
# applies (a draft is still "authored as" someone).
sub save_draft {
    my ($self, $email, $jwt, $message) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    $message = {} unless ref $message eq 'HASH';
    $message->{draft} = 1;

    if ($message->{in_reply_to}) {
        my ($msg_id, $refs) = eval { $self->_resolve_reply_headers($email, $jwt, $message->{in_reply_to}) };
        if ($@) { (my $m = $@) =~ s/\n$//; return { error => $m }; }
        $message->{in_reply_to_message_id} = $msg_id;
        $message->{references} = $refs;
    }

    my ($raw, $message_id) = eval { $self->_build_mime_message($email, $message) };
    if ($@) { (my $m = $@) =~ s/\n$//; return { error => $m }; }

    my ($draft_folder, $derr) = $self->_resolve_special_folder($email, $jwt, '\Drafts');
    return { error => $derr } if $derr;

    my (undef, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $r = $self->_imap_append($conn, $draft_folder, $raw, ['\Draft']);
        die "IMAP APPEND to Drafts failed\n" unless $r;
        return 1;
    });
    return { error => $err } if $err;
    return { success => 1, message_id => $message_id, folder => $draft_folder };
}

# Resolves in_reply_to into (in_reply_to_message_id, references). Accepts
# either a raw Message-ID string (caller already has it) or {folder, uid}
# (resolved here via the existing get_message, plus one extra targeted
# fetch for References since IMAP ENVELOPE's 10 fixed fields don't include
# it -- confirmed: _envelope_to_hash has no references key).
sub _resolve_reply_headers {
    my ($self, $email, $jwt, $in_reply_to) = @_;
    return (undef, undef) unless $in_reply_to;

    if (!ref $in_reply_to) {
        return ($in_reply_to, undef);
    }

    my ($folder, $uid) = @{$in_reply_to}{qw(folder uid)};
    die "Missing folder or uid for in_reply_to\n" unless $folder && $uid;

    my $orig = $self->get_message($email, $jwt, $folder, $uid);
    die "$orig->{error}\n" if $orig->{error};
    my $orig_msg_id = $orig->{headers}{message_id};
    die "Original message has no Message-ID to reply to\n" unless $orig_msg_id;

    my ($orig_references, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $folder);
        die $sel->{error} if $sel->{error};
        return $self->_imap_uid_fetch_references($conn, $uid) // '';
    });
    $orig_references = undef if $err || !length($orig_references // '');

    my $references = $orig_references ? "$orig_references $orig_msg_id" : $orig_msg_id;
    return ($orig_msg_id, $references);
}

# --- MIME message construction ------------------------------------------
#
# No CPAN MIME-building library is used here -- same low-dependency
# philosophy as the hand-rolled IMAP/SMTP wire protocol code elsewhere in
# this module. Text/HTML bodies are always base64-encoded (not quoted-
# printable) for simplicity and to sidestep QP line-length edge cases,
# matching how attachments are already encoded.

sub _build_mime_message {
    my ($self, $email, $message) = @_;

    my $from = $message->{from};
    die "Missing From address\n" unless defined $from && length $from;
    die "Invalid From address: $from\n" unless _validate_address($from);
    die "From address not authorized\n" unless $self->_from_address_authorized($email, $from);

    my @to  = @{ $message->{to}  || [] };
    my @cc  = @{ $message->{cc}  || [] };
    my @bcc = @{ $message->{bcc} || [] };
    die "Missing To recipients\n" unless @to || $message->{draft};
    for my $addr (@to, @cc, @bcc) {
        die "Invalid recipient address: $addr\n" unless _validate_address($addr);
    }

    my $subject = $message->{subject};
    die "Missing subject\n" unless defined $subject || $message->{draft};
    $subject //= '';

    my $has_text = defined $message->{text_body} && length $message->{text_body};
    my $has_html = defined $message->{html_body} && length $message->{html_body};
    die "Message must have a text or HTML body\n"
        unless $has_text || $has_html || $message->{draft};

    my $message_id = $self->_generate_message_id;
    my @headers;
    push @headers, _fold_header('Message-ID', $message_id);
    push @headers, _fold_header('Date', _rfc5322_date());
    push @headers, _fold_header('From', $from);
    push @headers, _fold_header('To', join(', ', @to)) if @to;
    push @headers, _fold_header('Cc', join(', ', @cc)) if @cc;
    # Bcc is deliberately never written into the message headers (RFC 5322
    # convention) -- it's used only for the SMTP envelope recipient list.
    push @headers, _fold_header('Subject', _encode_header_value($subject));
    push @headers, _fold_header('In-Reply-To', $message->{in_reply_to_message_id})
        if $message->{in_reply_to_message_id};
    push @headers, _fold_header('References', $message->{references})
        if $message->{references};
    push @headers, "MIME-Version: 1.0\r\n";

    my ($content_type, $transfer_encoding, $body) = $self->_build_multipart_body(
        $message->{text_body}, $message->{html_body}, $message->{attachments} || []
    );
    push @headers, _fold_header('Content-Type', $content_type);
    push @headers, "Content-Transfer-Encoding: $transfer_encoding\r\n" if defined $transfer_encoding;

    my $raw = join('', @headers) . "\r\n" . $body;

    my $max_bytes = $self->{max_message_size_mb} * 1024 * 1024;
    die "Message exceeds maximum size of $self->{max_message_size_mb}MB\n"
        if length($raw) > $max_bytes;

    return ($raw, $message_id);
}

sub _validate_address {
    my ($addr) = @_;
    return defined $addr && $addr =~ /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
}

sub _generate_message_id {
    my ($self) = @_;
    my $rand = unpack('H*', urandom(16));
    my $host = $self->{smtp}{host} || 'localhost';
    return "<$rand\@$host>";
}

sub _rfc5322_date {
    return DateTime->now(time_zone => 'local')->strftime('%a, %d %b %Y %H:%M:%S %z');
}

sub _encode_header_value {
    my ($str) = @_;
    return '' unless defined $str;
    return $str if $str =~ /^[\x20-\x7E]*$/; # pure ASCII, no encoding needed
    return Encode::encode('MIME-Header', $str);
}

# Simple RFC 5322 header folding at ~78 columns -- breaks on the last
# space before the column limit, continuation lines prefixed with a
# single space.
sub _fold_header {
    my ($name, $value) = @_;
    my $line = "$name: $value";
    return "$line\r\n" if length($line) <= 78;
    my @out;
    while (length($line) > 78) {
        my $break = rindex($line, ' ', 78);
        $break = 78 if $break < 1;
        push @out, substr($line, 0, $break);
        $line = ' ' . substr($line, $break + 1);
    }
    push @out, $line;
    return join("\r\n", @out) . "\r\n";
}

sub _mime_boundary {
    return 'homelab-' . unpack('H*', urandom(12));
}

# One MIME part's headers + base64 body (NOT including the leading
# "--boundary" line -- callers add that when assembling a multipart body).
sub _mime_leaf {
    my (%opts) = @_;
    my @header_lines = ("Content-Type: $opts{content_type}");
    if ($opts{filename}) {
        push @header_lines, sprintf('Content-Disposition: %s; filename="%s"',
            $opts{disposition} || 'attachment', _encode_header_value($opts{filename}));
    }
    push @header_lines, 'Content-Transfer-Encoding: base64';
    my $b64 = encode_base64($opts{bytes} // '', "\r\n");
    return join("\r\n", @header_lines) . "\r\n\r\n" . $b64;
}

# Returns ($content_type, $transfer_encoding, $body). $transfer_encoding
# is defined only for a single-part (non-multipart) body -- multipart
# bodies encode each part's own Content-Transfer-Encoding individually
# and have no top-level one (so the caller shouldn't emit that header).
sub _build_multipart_body {
    my ($self, $text_body, $html_body, $attachments) = @_;
    my $has_text = defined $text_body && length $text_body;
    my $has_html = defined $html_body && length $html_body;
    $attachments = [] unless ref $attachments eq 'ARRAY';

    my ($inner_ct, $inner_te, $inner_body);
    if ($has_text && $has_html) {
        my $b = _mime_boundary();
        my $part1 = _mime_leaf(content_type => 'text/plain; charset=UTF-8', bytes => $text_body);
        my $part2 = _mime_leaf(content_type => 'text/html; charset=UTF-8', bytes => $html_body);
        $inner_body = "--$b\r\n$part1\r\n--$b\r\n$part2\r\n--$b--\r\n";
        $inner_ct = qq{multipart/alternative; boundary="$b"};
        $inner_te = undef;
    } else {
        my $bytes = $has_html ? $html_body : ($text_body // '');
        $inner_ct = $has_html ? 'text/html; charset=UTF-8' : 'text/plain; charset=UTF-8';
        $inner_te = 'base64';
        $inner_body = encode_base64($bytes, "\r\n");
    }

    return ($inner_ct, $inner_te, $inner_body) unless @$attachments;

    my $b = _mime_boundary();
    my @parts;
    push @parts, defined $inner_te
        ? "Content-Type: $inner_ct\r\nContent-Transfer-Encoding: $inner_te\r\n\r\n$inner_body"
        : "Content-Type: $inner_ct\r\n\r\n$inner_body";
    for my $att (@$attachments) {
        push @parts, _mime_leaf(
            content_type => $att->{content_type} || 'application/octet-stream',
            bytes        => $att->{bytes},
            filename     => $att->{filename},
            disposition  => 'attachment',
        );
    }
    my $mixed_body = join('', map { "--$b\r\n$_\r\n" } @parts) . "--$b--\r\n";
    return (qq{multipart/mixed; boundary="$b"}, undef, $mixed_body);
}

# Phase 3: mutating operations. Everything above this point only ever uses
# .PEEK FETCHes -- nothing could accidentally change a live mailbox. From
# here down that's no longer true, so each method documents specifically
# how it avoids surprising/irreversible damage.

# Finds messages matching %criteria via IMAP SEARCH. Every string-valued
# criterion is routed through _imap_quote -- never interpolate user input
# directly into the SEARCH command line. Returns full headers (same shape
# as list_messages), newest first, capped at $criteria->{limit}.
sub search_messages {
    my ($self, $email, $jwt, $folder, $criteria) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    $folder = 'INBOX' unless defined $folder && length $folder;
    $criteria = {} unless ref $criteria eq 'HASH';

    my $search_str = eval { _build_search_criteria($criteria) };
    if ($@) {
        (my $msg = $@) =~ s/\n$//;
        return { error => $msg };
    }

    my $limit = $criteria->{limit};
    $limit = 50 unless defined $limit && $limit =~ /^\d+$/ && $limit > 0;
    $limit = 200 if $limit > 200;

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $folder);
        die $sel->{error} if $sel->{error};

        my $uids = $self->_imap_uid_search($conn, $search_str);
        die "IMAP SEARCH command failed\n" unless $uids;
        return { total => 0, messages => [] } unless @$uids;

        my @wanted = reverse @$uids; # newest first
        my $total  = scalar @wanted;
        @wanted = @wanted[0 .. $limit - 1] if @wanted > $limit;

        my $messages = $self->_imap_uid_fetch_headers($conn, join(',', @wanted));
        die "IMAP FETCH command failed\n" unless $messages;

        # _imap_uid_fetch_headers' result order follows the server's FETCH
        # response order, not necessarily @wanted's -- reorder to match.
        my %by_uid = map { $_->{uid} => $_ } @$messages;
        return { total => $total, messages => [ grep { $_ } map { $by_uid{$_ + 0} } @wanted ] };
    });
    return { error => $err } if $err;
    return { success => 1, folder => $folder, %$result };
}

# Adds/removes flags on a message. One general primitive (matching
# get_part's "one thing handles every content type" style) rather than
# separate mark-read/mark-unread/flag/unflag methods -- callers pass
# add=>['\Seen'] or remove=>['\Seen'] etc.
sub set_flags {
    my ($self, $email, $jwt, $folder, $uid, $add, $remove) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder or uid' } unless $folder && $uid;
    $add    = [] unless ref $add eq 'ARRAY';
    $remove = [] unless ref $remove eq 'ARRAY';
    return { error => 'Must specify at least one flag to add or remove' }
        unless @$add || @$remove;
    for (@$add, @$remove) {
        return { error => "Invalid flag: $_" } unless /^\\?[A-Za-z0-9]+$/;
    }

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $folder);
        die $sel->{error} if $sel->{error};

        my $existing = $self->_imap_uid_fetch($conn, $uid, 'FLAGS');
        die "IMAP FETCH command failed\n" unless $existing;
        die "Message not found: UID $uid\n" unless %$existing;

        if (@$add) {
            my $r = $self->_imap_uid_store($conn, $uid, '+FLAGS', $add);
            die "IMAP STORE command failed\n" unless $r;
        }
        if (@$remove) {
            my $r = $self->_imap_uid_store($conn, $uid, '-FLAGS', $remove);
            die "IMAP STORE command failed\n" unless $r;
        }

        my $final = $self->_imap_uid_fetch($conn, $uid, 'FLAGS');
        die "IMAP FETCH command failed\n" unless $final;
        return { flags => $final->{FLAGS} || [] };
    });
    return { error => $err } if $err;
    return { success => 1, uid => $uid + 0, flags => $result->{flags} };
}

# Moves a message to another folder via the confirmed MOVE capability
# (RFC 6851) -- one atomic command, not a COPY+STORE+EXPUNGE dance.
sub move_message {
    my ($self, $email, $jwt, $folder, $uid, $dest_folder) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder, uid, or destination folder' }
        unless $folder && $uid && defined $dest_folder && length $dest_folder;
    return { error => 'Source and destination folder are the same' }
        if $folder eq $dest_folder;

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $folder);
        die $sel->{error} if $sel->{error};

        my $existing = $self->_imap_uid_fetch($conn, $uid, 'FLAGS');
        die "IMAP FETCH command failed\n" unless $existing;
        die "Message not found: UID $uid\n" unless %$existing;

        my $r = $self->_imap_uid_move($conn, $uid, $dest_folder);
        die "IMAP MOVE command failed\n" unless $r;

        # MOVE doesn't change which mailbox is SELECTed (RFC 6851), but the
        # source folder's message count just changed -- rather than
        # tracking that incrementally, drop the cached selection entirely
        # so the next _imap_select call gets a fresh, correct EXISTS.
        if (defined $conn->{selected_mailbox} && $conn->{selected_mailbox} eq $folder) {
            delete $conn->{selected_mailbox};
            delete $conn->{selected_exists};
        }
        return { new_uid => $r->{new_uid} };
    });
    return { error => $err } if $err;
    # uid is the message's UID in its NEW folder, which is generally NOT
    # the same number as the UID it had in the source folder (UIDs are
    # per-mailbox) -- callers must use this value, not the one they
    # passed in, for any follow-up operation on the moved message.
    return {
        success       => 1,
        uid           => defined $result->{new_uid} ? $result->{new_uid} + 0 : undef,
        previous_uid  => $uid + 0,
        folder        => $dest_folder,
    };
}

# Soft delete: moves a message to whatever folder is marked \Trash. Never
# guesses a folder name -- see _resolve_trash_folder.
sub delete_message {
    my ($self, $email, $jwt, $folder, $uid) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder or uid' } unless $folder && $uid;

    my ($trash, $terr) = $self->_resolve_trash_folder($email, $jwt);
    return { error => $terr } if $terr;
    return { error => 'Message is already in Trash' } if $folder eq $trash;

    my $result = $self->move_message($email, $jwt, $folder, $uid, $trash);
    return $result if $result->{error};
    return { success => 1, uid => $result->{uid}, trash_folder => $trash };
}

# Hard delete -- permanent, irreversible. Deliberately takes NO $folder
# argument anywhere in its signature: it resolves and selects Trash
# itself, so a caller (buggy or malicious) cannot redirect it at a live
# mailbox. Requires the UID to already be found *inside* the resolved
# Trash folder specifically (a UID that's alive elsewhere under the same
# number fails closed as "not found"). Uses UID EXPUNGE (UIDPLUS) so only
# this one message is ever removed, never a bare mailbox-wide EXPUNGE.
sub expunge_message {
    my ($self, $email, $jwt, $uid) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing uid' } unless $uid;

    my ($trash, $terr) = $self->_resolve_trash_folder($email, $jwt);
    return { error => $terr } if $terr;

    my ($result, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $sel = $self->_imap_select($conn, $trash);
        die $sel->{error} if $sel->{error};

        my $existing = $self->_imap_uid_fetch($conn, $uid, 'FLAGS');
        die "IMAP FETCH command failed\n" unless $existing;
        die "Message not found in Trash: UID $uid\n" unless %$existing;

        my $r = $self->_imap_uid_store($conn, $uid, '+FLAGS', ['\\Deleted']);
        die "IMAP STORE command failed\n" unless $r;

        $r = $self->_imap_uid_expunge($conn, $uid);
        die "IMAP UID EXPUNGE command failed\n" unless $r;

        delete $conn->{selected_mailbox};
        delete $conn->{selected_exists};
        return 1;
    });
    return { error => $err } if $err;
    return { success => 1, uid => $uid + 0, trash_folder => $trash };
}

# Resolves "the" folder carrying a given \SpecialUse flag (\Trash, \Sent,
# \Drafts, ...) via list_folders' special_use data. Fails closed -- errors
# clearly if zero or more than one folder carries the flag, rather than
# guessing a name like "Trash"/"Sent": a wrong guess could silently
# misfile mail, or worse, point a hard-delete or a Sent/Drafts copy at the
# wrong folder. Not cached across calls: one extra cheap LIST per call
# beats risking a stale folder name after a rename.
sub _resolve_special_folder {
    my ($self, $email, $jwt, $use) = @_;
    my $result = $self->list_folders($email, $jwt);
    return (undef, $result->{error}) if $result->{error};
    my @matches = grep {
        grep { /^\Q$use\E$/i } @{ $_->{special_use} || [] }
    } @{ $result->{folders} || [] };
    return (undef, "No folder marked $use found on this account") unless @matches;
    return (undef, "Multiple folders marked $use found on this account") if @matches > 1;
    return ($matches[0]{name}, undef);
}

sub _resolve_trash_folder {
    my ($self, $email, $jwt) = @_;
    return $self->_resolve_special_folder($email, $jwt, '\Trash');
}

sub create_folder {
    my ($self, $email, $jwt, $name) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder name' } unless defined $name && length $name;

    my (undef, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $r = $self->_imap_create($conn, $name);
        die "Folder already exists: $name\n" if ref $r eq 'HASH' && $r->{exists};
        die "IMAP CREATE command failed\n" unless $r;
        return 1;
    });
    return { error => $err } if $err;
    return { success => 1, folder => $name };
}

# Refuses to rename INBOX or any folder carrying a special-use flag
# (Trash/Sent/Drafts/Archive/Junk) -- see _is_protected_folder, which
# fails CLOSED (refuses the operation) if it can't even verify safety.
sub rename_folder {
    my ($self, $email, $jwt, $name, $new_name) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder name or new name' }
        unless defined $name && length $name && defined $new_name && length $new_name;

    my ($protected, $perr) = $self->_is_protected_folder($email, $jwt, $name);
    return { error => $perr } if $perr;
    return { error => 'Cannot rename a special-use folder' } if $protected;

    my (undef, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $r = $self->_imap_rename($conn, $name, $new_name);
        die "Folder not found: $name\n" if ref $r eq 'HASH' && $r->{not_found};
        die "IMAP RENAME command failed\n" unless $r;
        if (defined $conn->{selected_mailbox} && $conn->{selected_mailbox} eq $name) {
            delete $conn->{selected_mailbox};
            delete $conn->{selected_exists};
        }
        return 1;
    });
    return { error => $err } if $err;
    return { success => 1, folder => $new_name };
}

sub delete_folder {
    my ($self, $email, $jwt, $name) = @_;
    return { error => 'Missing email or token' } unless $email && $jwt;
    return { error => 'Missing folder name' } unless defined $name && length $name;

    my ($protected, $perr) = $self->_is_protected_folder($email, $jwt, $name);
    return { error => $perr } if $perr;
    return { error => 'Cannot delete a special-use folder' } if $protected;

    my (undef, $err) = $self->_with_connection($email, $jwt, sub {
        my ($conn) = @_;
        my $r = $self->_imap_delete_mailbox($conn, $name);
        die "Folder not found: $name\n" if ref $r eq 'HASH' && $r->{not_found};
        die "IMAP DELETE command failed\n" unless $r;
        if (defined $conn->{selected_mailbox} && $conn->{selected_mailbox} eq $name) {
            delete $conn->{selected_mailbox};
            delete $conn->{selected_exists};
        }
        return 1;
    });
    return { error => $err } if $err;
    return { success => 1, folder => $name };
}

# Fails CLOSED: if the list_folders call this depends on itself errors,
# returns an error (refusing the caller's rename/delete) rather than
# silently treating "couldn't check" as "not protected" -- a transient
# LIST failure must never be the reason a special-use folder gets
# renamed/deleted out from under an account.
sub _is_protected_folder {
    my ($self, $email, $jwt, $name) = @_;
    return (1, undef) if uc($name) eq 'INBOX';
    my $result = $self->list_folders($email, $jwt);
    return (undef, $result->{error}) if $result->{error};
    my ($f) = grep { $_->{name} eq $name } @{ $result->{folders} || [] };
    return (($f && @{ $f->{special_use} || [] }) ? 1 : 0, undef);
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

# Same as _imap_fetch_headers but against an explicit UID set (comma-
# joined, e.g. "12,45,99") rather than a sequence-number range -- used by
# search_messages, where the interesting messages are scattered UIDs, not
# a contiguous range.
sub _imap_uid_fetch_headers {
    my ($self, $conn, $uid_set) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag UID FETCH $uid_set (UID FLAGS ENVELOPE RFC822.SIZE)");
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

sub _imap_uid_search {
    my ($self, $conn, $search_str) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag UID SEARCH $search_str");
        my @uids;
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            if ($resp =~ /^\*\s+SEARCH\s*(.*)$/i) {
                @uids = split /\s+/, $1 if length $1;
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
        }
        die "SEARCH failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return [ map { $_ + 0 } @uids ];
    });
    return undef if $err;
    return $result;
}

# $op is '+FLAGS' or '-FLAGS'. .SILENT suppresses the untagged FETCH reply
# (callers re-fetch FLAGS explicitly afterward for a guaranteed-fresh
# value rather than trusting/parsing this response).
sub _imap_uid_store {
    my ($self, $conn, $uid, $op, $flags) = @_;
    my $flags_str = '(' . join(' ', @$flags) . ')';
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag UID STORE $uid $op.SILENT $flags_str");
        my $resp = _imap_read_response_line($conn);
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_response_line($conn);
        }
        die "STORE failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return 1;
    });
    return undef if $err;
    return $result;
}

# UIDs are per-mailbox, not global -- a message moved into another folder
# gets a NEW UID there, which is NOT the same number as its source UID
# (they can coincidentally match, especially in an empty destination
# folder, but that's not guaranteed by the protocol). Since UIDPLUS is
# confirmed available, a successful MOVE's response includes an untagged
# "OK [COPYUID <uidvalidity> <source-uids> <dest-uids>]" line -- parse
# that to learn the real new UID rather than assuming it's unchanged.
# Returns {new_uid => N} on success (new_uid is undef if the server
# didn't include COPYUID for some reason -- callers should treat that as
# "unknown, re-list the destination folder to find it").
sub _imap_uid_move {
    my ($self, $conn, $uid, $dest_folder) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag UID MOVE $uid " . _imap_quote($dest_folder));
        my $new_uid;
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            if ($resp =~ /^\*\s+OK\s+\[COPYUID\s+\S+\s+\S+\s+(\S+)\]/i) {
                ($new_uid) = $1 =~ /^(\d+)/; # dest-uidset for one message is one number
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
        }
        die "Destination folder not found: $dest_folder\n"
            if defined $resp && $resp =~ /^\Q$tag\E\s+NO/i;
        die "MOVE failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return { new_uid => $new_uid };
    });
    return undef if $err;
    return $result;
}

# UIDPLUS's targeted expunge -- removes only $uid, never a bare mailbox-
# wide EXPUNGE that would remove every \Deleted-flagged message.
sub _imap_uid_expunge {
    my ($self, $conn, $uid) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag UID EXPUNGE $uid");
        my $resp = _imap_read_response_line($conn);
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_response_line($conn);
        }
        die "UID EXPUNGE failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return 1;
    });
    return undef if $err;
    return $result;
}

# Real APPEND (Phase 4), usable outside tests -- save_draft appends a
# drafted message, send_message appends a Sent copy after a successful
# SMTP transaction. Runs inside an existing pooled $conn from
# _with_connection, exactly like every other _imap_* helper here (t/mail.t
# has its own separate test-only APPEND that hand-rolls its own AUTH from
# scratch for test isolation -- that one stays as-is).
sub _imap_append {
    my ($self, $conn, $folder, $raw_message, $flags) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout} + 15, sub {
        my $tag = _imap_next_tag($conn);
        my $flag_str = (@{ $flags || [] }) ? '(' . join(' ', @$flags) . ') ' : '';
        my $n = length($raw_message);
        _imap_send($conn, "$tag APPEND " . _imap_quote($folder) . " $flag_str\{$n}");
        my $cont = _imap_read_response_line($conn);
        die "APPEND not accepted\n" unless defined $cont && $cont =~ /^\+/;
        $conn->{sock}->print($raw_message);
        $conn->{sock}->print("\r\n");
        my $resp = _imap_read_response_line($conn);
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_response_line($conn);
        }
        die "Folder not found: $folder\n" if defined $resp && $resp =~ /^\Q$tag\E\s+NO/i;
        die "APPEND failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return 1;
    });
    return undef if $err;
    return $result;
}

# Fetches just the raw References header text for one message -- needed
# for reply threading since IMAP ENVELOPE's 10 fixed fields don't include
# it. Uses a direct regex scan for "BODY[...]" rather than the generic
# _imap_parse_fetch_items tokenizer, since HEADER.FIELDS (REFERENCES)'s
# own internal parens/space would confuse that tokenizer's atom-stops-at-
# paren rule (which is correct for BODY[1]-style plain part numbers, but
# not for this item name shape).
sub _imap_uid_fetch_references {
    my ($self, $conn, $uid) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag UID FETCH $uid (BODY.PEEK[HEADER.FIELDS (REFERENCES)])");
        my $text;
        my $resp = _imap_read_response_line($conn);
        while (defined $resp) {
            if ($resp =~ /BODY\[[^\]]*\]\s*(\x00LIT\x00\d+\x00.*)/is) {
                ($text) = _imap_parse_token($1, 0);
            }
            last if $resp =~ /^\Q$tag\E\s/;
            $resp = _imap_read_response_line($conn);
        }
        die "UID FETCH failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return $text;
    });
    return undef if $err;
    return undef unless defined $result;
    $result =~ s/^References:\s*//i;
    $result =~ s/\s+$//;
    return length($result) ? $result : undef;
}

sub _imap_create {
    my ($self, $conn, $name) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag CREATE " . _imap_quote($name));
        my $resp = _imap_read_response_line($conn);
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_response_line($conn);
        }
        return { exists => 1 } if defined $resp && $resp =~ /^\Q$tag\E\s+NO/i;
        die "CREATE failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return 1;
    });
    return undef if $err;
    return $result;
}

sub _imap_rename {
    my ($self, $conn, $name, $new_name) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag RENAME " . _imap_quote($name) . ' ' . _imap_quote($new_name));
        my $resp = _imap_read_response_line($conn);
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_response_line($conn);
        }
        return { not_found => 1 } if defined $resp && $resp =~ /^\Q$tag\E\s+NO/i;
        die "RENAME failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return 1;
    });
    return undef if $err;
    return $result;
}

sub _imap_delete_mailbox {
    my ($self, $conn, $name) = @_;
    my ($result, $err) = $self->_with_timeout($self->{imap}{command_timeout}, sub {
        my $tag = _imap_next_tag($conn);
        _imap_send($conn, "$tag DELETE " . _imap_quote($name));
        my $resp = _imap_read_response_line($conn);
        while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
            $resp = _imap_read_response_line($conn);
        }
        return { not_found => 1 } if defined $resp && $resp =~ /^\Q$tag\E\s+NO/i;
        die "DELETE failed\n" unless defined $resp && $resp =~ /^\Q$tag\E OK/i;
        return 1;
    });
    return undef if $err;
    return $result;
}

# Builds one IMAP SEARCH criteria string from a plain-hash request. Every
# string value goes through _imap_quote -- never interpolated raw, which
# is what would otherwise open an IMAP command-injection vector (e.g. a
# subject of `foo" BODY "bar` smuggling in extra search terms). Dies with
# a plain, caller-facing message (no trailing IMAP jargon) on invalid
# input; the caller catches this and maps it to 400. No raw sequence/UID-
# range passthrough is exposed -- this is a semantic search, not a raw
# SEARCH-command passthrough.
sub _build_search_criteria {
    my ($criteria) = @_;
    my @parts;

    die "Cannot specify both unseen and seen\n" if $criteria->{unseen} && $criteria->{seen};
    die "Cannot specify both flagged and unflagged\n" if $criteria->{flagged} && $criteria->{unflagged};

    push @parts, 'UNSEEN'    if $criteria->{unseen};
    push @parts, 'SEEN'      if $criteria->{seen};
    push @parts, 'FLAGGED'   if $criteria->{flagged};
    push @parts, 'UNFLAGGED' if $criteria->{unflagged};

    for my $key (qw(from to subject body)) {
        my $val = $criteria->{$key};
        next unless defined $val && length $val;
        push @parts, uc($key) . ' ' . _imap_quote($val);
    }

    for my $pair (['since', 'SINCE'], ['before', 'BEFORE']) {
        my ($key, $imap_word) = @$pair;
        my $val = $criteria->{$key};
        next unless defined $val && length $val;
        die "Invalid date for '$key' (expected YYYY-MM-DD): $val\n"
            unless $val =~ /^(\d{4})-(\d{2})-(\d{2})$/;
        my ($y, $mon, $d) = ($1, $2, $3);
        my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        my $mon_name = $months[$mon - 1] or die "Invalid date for '$key': $val\n";
        push @parts, "$imap_word $d-$mon_name-$y";
    }

    return @parts ? join(' ', @parts) : 'ALL';
}

# --- SMTP wire protocol ----------------------------------------------------
#
# Hand-rolled over IO::Socket::SSL, same low-dependency philosophy as the
# IMAP wire protocol above -- no Net::SMTP/Authen::SASL dependency added.
# Confirmed working against production (mail.mailmasker.org:465, implicit
# TLS, AUTH OAUTHBEARER succeeding on the first attempt) via
# script/experiments/smtp-oauthbearer-poc.pl; see issue_tracking's
# Progress notes. Unlike IMAP, there is deliberately NO connection pool --
# sending is comparatively rare and stateless per transaction (no long-
# lived SELECT-style state worth preserving), so _with_smtp_connection
# just connects fresh, runs one transaction, and always tears down,
# retrying the whole thing once on failure using the CURRENT request's JWT.

sub _with_smtp_connection {
    my ($self, $email, $jwt, $code) = @_;
    my $conn = $self->_smtp_connect($email, $jwt);
    return (undef, $conn->{error}) if $conn->{error};

    my $result = eval { $code->($conn) };
    my $err = $@;
    $self->_smtp_quit($conn);

    if (!$result) {
        $conn = $self->_smtp_connect($email, $jwt);
        return (undef, $conn->{error}) if $conn->{error};
        $result = eval { $code->($conn) };
        $err = $@;
        $self->_smtp_quit($conn);
        return (undef, $err || 'SMTP command failed') unless $result;
    }
    return ($result, undef);
}

# RFC 5321 multi-line framing: "250-foo\r\n250-bar\r\n250 baz\r\n" -- a
# dash after the code means more lines follow, a space means the last
# line. Completely different shape from IMAP's tag-based scheme; SMTP has
# no tags at all. Returns ($code, \@lines).
sub _smtp_read_response {
    my ($conn) = @_;
    my (@lines, $code);
    while (1) {
        my $line = $conn->{sock}->getline;
        return (undef, \@lines) unless defined $line;
        $line =~ s/\r?\n\z//;
        push @lines, $line;
        if ($line =~ /^(\d{3})([ -])/) {
            $code = $1;
            last if $2 eq ' ';
        } else {
            last;
        }
    }
    return ($code, \@lines);
}

sub _smtp_send {
    my ($conn, $line) = @_;
    $conn->{sock}->print("$line\r\n");
}

sub _smtp_command {
    my ($self, $conn, $line) = @_;
    _smtp_send($conn, $line);
    return _smtp_read_response($conn);
}

sub _smtp_connect {
    my ($self, $email, $jwt) = @_;
    my ($conn, $err) = $self->_with_timeout($self->{smtp}{connect_timeout}, sub {
        my $sock = IO::Socket::SSL->new(
            PeerHost => $self->{smtp}{host},
            PeerPort => $self->{smtp}{port},
        ) or die "connect to $self->{smtp}{host}:$self->{smtp}{port} failed: "
            . IO::Socket::SSL::errstr() . "\n";
        my $c = { sock => $sock };

        my ($greet_code) = _smtp_read_response($c);
        die "SMTP greeting failed\n" unless defined $greet_code && $greet_code eq '220';

        _smtp_send($c, 'EHLO homelab-api');
        my ($ehlo_code, $ehlo_lines) = _smtp_read_response($c);
        die "EHLO failed\n" unless defined $ehlo_code && $ehlo_code eq '250';

        my ($auth_line) = grep { /^\d{3}[ -]AUTH\b/i } @$ehlo_lines;
        my @mechs;
        push @mechs, 'OAUTHBEARER' if $auth_line && $auth_line =~ /\bOAUTHBEARER\b/i;
        push @mechs, 'XOAUTH2'     if $auth_line && $auth_line =~ /\bXOAUTH2\b/i;
        die "Server does not advertise OAUTHBEARER or XOAUTH2\n" unless @mechs;

        my $authed;
        for my $mech (@mechs) {
            my $sasl = $mech eq 'OAUTHBEARER'
                ? "n,a=$email,\x01host=$self->{smtp}{host}\x01port=$self->{smtp}{port}\x01auth=Bearer $jwt\x01\x01"
                : "user=$email\x01auth=Bearer $jwt\x01\x01";
            _smtp_send($c, "AUTH $mech " . encode_base64($sasl, ''));
            my ($code) = _smtp_read_response($c);
            if (defined $code && $code eq '334') {
                # SASL continuation -- for a failed attempt this is a
                # base64 JSON error blob (RFC 7628 3.2.3); an empty line
                # completes the failed exchange.
                _smtp_send($c, '');
                ($code) = _smtp_read_response($c);
            }
            if (defined $code && $code eq '235') {
                $authed = $mech;
                last;
            }
            # Reset with a fresh EHLO before trying the next mechanism.
            _smtp_send($c, 'EHLO homelab-api');
            _smtp_read_response($c);
        }
        die "AUTH failed for $email\n" unless $authed;
        return $c;
    });
    return { error => "SMTP auth failed for $email: $err" } if $err;
    return $conn;
}

# RFC 5321 4.5.2 dot-stuffing: any line starting with "." gets an extra
# "." prefix, and the message is terminated with the standard "\r\n.\r\n".
sub _smtp_send_data {
    my ($self, $conn, $raw_message) = @_;
    my ($result, $err) = $self->_with_timeout($self->{smtp}{data_timeout}, sub {
        my ($data_code) = $self->_smtp_command($conn, 'DATA');
        die "DATA not accepted\n" unless defined $data_code && $data_code eq '354';

        (my $stuffed = $raw_message) =~ s/^\./../mg;
        $conn->{sock}->print($stuffed);
        $conn->{sock}->print("\r\n.\r\n");

        my ($sent_code) = _smtp_read_response($conn);
        die "Message not accepted after DATA\n" unless defined $sent_code && $sent_code eq '250';
        return 1;
    });
    return undef if $err;
    return $result;
}

sub _smtp_quit {
    my ($self, $conn) = @_;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(2);
        _smtp_send($conn, 'QUIT');
        _smtp_read_response($conn);
        alarm(0);
    };
    alarm(0);
    eval { $conn->{sock}->close };
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
