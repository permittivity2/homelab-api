#!/usr/bin/env perl
# Throwaway feasibility spike for issue #015 (Mail API / Dovecot IMAP).
#
# NOT part of the shipped app: not in MANIFEST, not in Makefile.PL's
# EXE_FILES, not packaged in any debian/ control file. Exists only to
# answer one question: can we get from a homelab-api JWT to an
# authenticated IMAP session against Dovecot, and if so, via which
# mechanism (Mail::IMAPClient vs a hand-rolled AUTHENTICATE OAUTHBEARER/
# XOAUTH2 exchange over a raw socket)?
#
# Usage:
#   perl imap-oauthbearer-poc.pl --email you\@example.com --jwt eyJ... \
#       [--host imap.mailmasker.org] [--port 993]
#
# Get a JWT via: homelab-cli login   (then read ~/.config/homelab-cli/session.json)
# Use YOUR OWN test mailbox only. This script never runs anything beyond
# AUTHENTICATE / CAPABILITY / STATUS / LOGOUT — no FETCH, no STORE, nothing
# destructive or private-data-reading — so it's safe to re-run repeatedly.

use strict;
use warnings;
use Getopt::Long;
use MIME::Base64 qw(encode_base64);
use IO::Socket::SSL;

my ($email, $jwt, $host, $port) = (undef, undef, 'imap.mailmasker.org', 993);
GetOptions(
    'email=s' => \$email,
    'jwt=s'   => \$jwt,
    'host=s'  => \$host,
    'port=i'  => \$port,
) or die "Usage: $0 --email E --jwt JWT [--host H] [--port P]\n";

die "Usage: $0 --email E --jwt JWT [--host H] [--port P]\n"
    unless $email && $jwt;

print "=== Phase 0 IMAP OAUTHBEARER/XOAUTH2 feasibility spike ===\n";
print "Target: $host:$port  Email: $email\n\n";

# --- Attempt 1: Mail::IMAPClient, if it's even installed ------------------
print "--- Attempt 1: Mail::IMAPClient ---\n";
my $imapclient_ok = eval { require Mail::IMAPClient; 1 };
if (!$imapclient_ok) {
    print "SKIP: Mail::IMAPClient is not installed in this environment.\n";
    print "      (This alone doesn't rule it out for production -- api01 may\n";
    print "       have it installed as a system package. But its SASL\n";
    print "       mechanism list historically does not include OAUTHBEARER/\n";
    print "       XOAUTH2, so the raw-socket path below is the one that\n";
    print "       actually matters for this decision.)\n\n";
} else {
    print "Mail::IMAPClient version $Mail::IMAPClient::VERSION is available.\n";
    my $imap = eval {
        Mail::IMAPClient->new(
            Server   => $host,
            Port     => $port,
            Ssl      => 1,
            User     => $email,
            Password => $jwt, # only relevant if a XOAUTH2-aware Authmechanism exists
        );
    };
    if (!$imap) {
        print "FAIL: could not construct Mail::IMAPClient object: $@\n\n";
    } else {
        my @mechs = eval { $imap->authmechanisms } // ();
        print "Advertised/supported Authmechanism list: @mechs\n";
        print "RESULT: Mail::IMAPClient has no first-class XOAUTH2/OAUTHBEARER\n";
        print "        support call in this spike -- treat as FAIL unless you\n";
        print "        find and wire up an Authcallback override by hand.\n\n";
    }
}

# --- Attempt 2: raw socket, hand-rolled AUTHENTICATE OAUTHBEARER/XOAUTH2 --
print "--- Attempt 2: raw IO::Socket::SSL, hand-rolled SASL ---\n";

sub read_line {
    my ($sock) = @_;
    my $line = $sock->getline;
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    print "S: $line\n";
    return $line;
}

sub send_line {
    my ($sock, $line) = @_;
    print "C: $line\n";
    $sock->print("$line\r\n");
}

# Read (possibly multi-line) response to a tagged command, ending when a
# line begins with the given tag.
sub read_until_tagged {
    my ($sock, $tag) = @_;
    my @lines;
    while (defined(my $line = read_line($sock))) {
        push @lines, $line;
        return @lines if $line =~ /^\Q$tag\E\s/;
    }
    return @lines;
}

my $sock = IO::Socket::SSL->new(
    PeerHost => $host,
    PeerPort => $port,
    Timeout  => 10,
) or do {
    print "FAIL: could not connect: " . IO::Socket::SSL::errstr() . "\n";
    exit 1;
};

my $greeting = read_line($sock);
print "\n";

my $tagn = 0;
sub next_tag { return 'a' . ++$tagn }

my $tag = next_tag();
send_line($sock, "$tag CAPABILITY");
my @cap_lines = read_until_tagged($sock, $tag);
my ($cap_line) = grep { /^\* CAPABILITY/i } @cap_lines;
print "\n";

my $has_oauthbearer = $cap_line && $cap_line =~ /AUTH=OAUTHBEARER/i;
my $has_xoauth2      = $cap_line && $cap_line =~ /AUTH=XOAUTH2/i;
print "Server advertises: OAUTHBEARER=" . ($has_oauthbearer ? 'yes' : 'no')
    . " XOAUTH2=" . ($has_xoauth2 ? 'yes' : 'no') . "\n\n";

my $overall_ok = 0;

# Try OAUTHBEARER first (RFC 7628), then XOAUTH2 (older/more common), per
# whichever the server actually advertised above.
my @mechanisms_to_try;
push @mechanisms_to_try, 'OAUTHBEARER' if $has_oauthbearer;
push @mechanisms_to_try, 'XOAUTH2'     if $has_xoauth2;
push @mechanisms_to_try, 'OAUTHBEARER', 'XOAUTH2' unless @mechanisms_to_try; # try anyway

for my $mech (@mechanisms_to_try) {
    print "--- Trying AUTHENTICATE $mech ---\n";

    my $sasl_str =
        $mech eq 'OAUTHBEARER'
        ? "n,a=$email,\x01host=$host\x01port=$port\x01auth=Bearer $jwt\x01\x01"
        : "user=$email\x01auth=Bearer $jwt\x01\x01"; # XOAUTH2 form

    my $b64 = encode_base64($sasl_str, '');
    $tag = next_tag();
    send_line($sock, "$tag AUTHENTICATE $mech $b64");
    my $resp = read_line($sock);

    if (defined $resp && $resp =~ /^\+/) {
        # Server is issuing a SASL continuation -- for a failed OAUTHBEARER
        # attempt this is typically a base64 JSON error blob, and RFC 7628
        # 3.2.3 requires the client send an empty line to complete the
        # failed exchange (rather than trying to interpret/retry inline).
        print "  (continuation received -- likely an auth error blob; "
            . "completing the exchange with an empty response)\n";
        send_line($sock, '');
        $resp = read_line($sock);
    }

    # On a SUCCESSFUL login, Dovecot sends an untagged post-login
    # CAPABILITY line before the tagged OK -- keep reading until we see
    # this attempt's own tag, rather than assuming the very next line is
    # the tagged response (an earlier version of this script got this
    # wrong and mistook the untagged CAPABILITY line for a failure, then
    # went on to try a second AUTHENTICATE on an already-authenticated
    # connection).
    while (defined $resp && $resp !~ /^\Q$tag\E\s/) {
        $resp = read_line($sock);
    }

    if (defined $resp && $resp =~ /^\Q$tag\E OK/i) {
        print "SUCCESS: AUTHENTICATE $mech worked.\n\n";
        $overall_ok = $mech;
        last;
    } else {
        print "FAIL: AUTHENTICATE $mech did not succeed.\n\n";
    }
}

if ($overall_ok) {
    print "--- Post-auth sanity checks (mechanism: $overall_ok) ---\n";
    $tag = next_tag();
    send_line($sock, "$tag CAPABILITY");
    read_until_tagged($sock, $tag);
    print "\n";

    $tag = next_tag();
    send_line($sock, qq{$tag STATUS INBOX (MESSAGES UNSEEN)});
    read_until_tagged($sock, $tag);
    print "\n";
}

$tag = next_tag();
send_line($sock, "$tag LOGOUT");
read_until_tagged($sock, $tag);
$sock->close;

print "\n=== SUMMARY ===\n";
print "Mail::IMAPClient path: " . ($imapclient_ok ? 'installed, but no built-in OAUTHBEARER/XOAUTH2 support found' : 'not installed here') . "\n";
print "Raw-socket path: " . ($overall_ok ? "SUCCESS via $overall_ok" : 'FAILED for all attempted mechanisms') . "\n";
print "\nRecord this result in issue_tracking/015-dovecot-imap-api.md before\n";
print "starting Phase 1 (Homelab::Mail).\n";
