#!/usr/bin/env perl
# Throwaway feasibility spike for issue #015 Phase 4 (Mail API / SMTP send).
#
# NOT part of the shipped app: not in MANIFEST, not in Makefile.PL, not
# packaged in any debian/ control file. Exists only to answer one
# question: does a homelab-api JWT authenticate to Postfix's SMTP AUTH
# (via Dovecot's SASL delegation) the same way it already does for IMAP,
# and if so, via which mechanism (OAUTHBEARER or XOAUTH2)? Unlike IMAP,
# this was never root-caused -- issue #012's one real SMTP send test
# (XOAUTH2, via Roundcube) reached Gmail but nobody confirmed via
# server-side logs which mechanism actually authenticated it.
#
# Usage:
#   perl smtp-oauthbearer-poc.pl --email you\@example.com --jwt eyJ... \
#       [--from you\@example.com] [--to you\@example.com] \
#       [--host mail.mailmasker.org] [--port 465] \
#       [--force-different-recipient]
#
# Get a JWT via: homelab-cli login   (then read ~/.config/homelab-cli/session.json)
# By default --to defaults to --from (or --email) -- this script refuses
# to send to a different recipient unless --force-different-recipient is
# also given, so it can never spam an arbitrary third party by accident.

use strict;
use warnings;
use Getopt::Long;
use MIME::Base64 qw(encode_base64);
use IO::Socket::SSL;

my ($email, $jwt, $from, $to, $host, $port, $force_different) =
    (undef, undef, undef, undef, 'mail.mailmasker.org', 465, 0);
GetOptions(
    'email=s'                   => \$email,
    'jwt=s'                     => \$jwt,
    'from=s'                    => \$from,
    'to=s'                      => \$to,
    'host=s'                    => \$host,
    'port=i'                    => \$port,
    'force-different-recipient' => \$force_different,
) or die "Usage: $0 --email E --jwt JWT [--from F] [--to T] [--host H] [--port P] [--force-different-recipient]\n";

die "Usage: $0 --email E --jwt JWT [--from F] [--to T] [--host H] [--port P] [--force-different-recipient]\n"
    unless $email && $jwt;

$from //= $email;
$to   //= $from;
if (lc($to) ne lc($from) && !$force_different) {
    die "Refusing to send to '$to' (differs from --from '$from') without "
        . "--force-different-recipient. This safety default exists so this "
        . "throwaway script can never spam an arbitrary third party by accident.\n";
}

print "=== Phase 4a SMTP OAUTHBEARER/XOAUTH2 feasibility spike ===\n";
print "Target: $host:$port  Auth email: $email  From: $from  To: $to\n\n";

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

# SMTP multi-line responses look like "250-foo\r\n250-bar\r\n250 baz\r\n" --
# a dash after the code means "more lines follow," a space means "last
# line." Returns ($code, \@lines). This is RFC 5321 framing, NOT IMAP's
# tag-based scheme -- no tags exist in SMTP at all.
sub read_response {
    my ($sock) = @_;
    my (@lines, $code);
    while (1) {
        my $line = read_line($sock);
        return (undef, \@lines) unless defined $line;
        push @lines, $line;
        if ($line =~ /^(\d{3})([ -])/) {
            $code = $1;
            last if $2 eq ' ';
        } else {
            last; # malformed, bail out with whatever we have
        }
    }
    return ($code, \@lines);
}

my $sock = IO::Socket::SSL->new(
    PeerHost => $host,
    PeerPort => $port,
    Timeout  => 10,
) or do {
    print "FAIL: could not connect: " . IO::Socket::SSL::errstr() . "\n";
    exit 1;
};

my ($greet_code) = read_response($sock);
print "\n";
die "FAIL: no/bad greeting\n" unless defined $greet_code && $greet_code eq '220';

send_line($sock, "EHLO homelab-api-poc");
my ($ehlo_code, $ehlo_lines) = read_response($sock);
print "\n";
die "FAIL: EHLO not accepted (code: " . ($ehlo_code // 'none') . ")\n"
    unless defined $ehlo_code && $ehlo_code eq '250';

my ($auth_line) = grep { /^\d{3}[ -]AUTH\b/i } @$ehlo_lines;
my $has_oauthbearer = $auth_line && $auth_line =~ /\bOAUTHBEARER\b/i;
my $has_xoauth2     = $auth_line && $auth_line =~ /\bXOAUTH2\b/i;
print "Server advertises: OAUTHBEARER=" . ($has_oauthbearer ? 'yes' : 'no')
    . " XOAUTH2=" . ($has_xoauth2 ? 'yes' : 'no')
    . " (raw AUTH line: " . ($auth_line // '<none found>') . ")\n\n";

my $overall_ok = 0;
my @mechanisms_to_try;
push @mechanisms_to_try, 'OAUTHBEARER' if $has_oauthbearer;
push @mechanisms_to_try, 'XOAUTH2'     if $has_xoauth2;
push @mechanisms_to_try, 'OAUTHBEARER', 'XOAUTH2' unless @mechanisms_to_try; # try anyway

for my $mech (@mechanisms_to_try) {
    print "--- Trying AUTH $mech ---\n";

    my $sasl_str =
        $mech eq 'OAUTHBEARER'
        ? "n,a=$email,\x01host=$host\x01port=$port\x01auth=Bearer $jwt\x01\x01"
        : "user=$email\x01auth=Bearer $jwt\x01\x01"; # XOAUTH2 form

    my $b64 = encode_base64($sasl_str, '');
    send_line($sock, "AUTH $mech $b64");
    my ($code, $lines) = read_response($sock);

    if (defined $code && $code eq '334') {
        # SASL continuation -- for a failed OAUTHBEARER attempt this is a
        # base64 JSON error blob (RFC 7628 3.2.3); respond with an empty
        # line to complete the failed exchange rather than retrying inline.
        print "  (334 continuation received -- likely an auth error blob; "
            . "completing the exchange with an empty response)\n";
        send_line($sock, '');
        ($code, $lines) = read_response($sock);
    }

    if (defined $code && $code eq '235') {
        print "SUCCESS: AUTH $mech worked (235).\n\n";
        $overall_ok = $mech;
        last;
    } else {
        print "FAIL: AUTH $mech did not succeed (code: " . ($code // 'none') . ").\n\n";
        # Need a fresh EHLO after a failed AUTH attempt on some servers
        # before trying the next mechanism -- re-issue defensively.
        send_line($sock, "EHLO homelab-api-poc");
        read_response($sock);
        print "\n";
    }
}

if ($overall_ok) {
    print "--- Post-auth: sending a minimal real test message ---\n";
    send_line($sock, "MAIL FROM:<$from>");
    my ($mf_code) = read_response($sock);
    print "\n";
    die "FAIL: MAIL FROM rejected (code: " . ($mf_code // 'none') . ") -- "
        . "this is exactly the sender-authorization check this whole feature "
        . "depends on; a non-authorized --from would fail here.\n"
        unless defined $mf_code && $mf_code eq '250';

    send_line($sock, "RCPT TO:<$to>");
    my ($rcpt_code) = read_response($sock);
    print "\n";
    die "FAIL: RCPT TO rejected (code: " . ($rcpt_code // 'none') . ")\n"
        unless defined $rcpt_code && $rcpt_code eq '250';

    send_line($sock, "DATA");
    my ($data_code) = read_response($sock);
    print "\n";
    die "FAIL: DATA not accepted (code: " . ($data_code // 'none') . ")\n"
        unless defined $data_code && $data_code eq '354';

    my $subject = "[homelab-api SMTP spike] Phase 4a feasibility test $$ " . time();
    my $body = "Subject: $subject\r\n"
        . "From: $from\r\n"
        . "To: $to\r\n"
        . "Date: " . scalar(gmtime) . " +0000\r\n"
        . "\r\n"
        . "This is a throwaway feasibility-spike message for homelab-api issue #015\n"
        . "Phase 4 (send email). Mechanism used: $overall_ok. Safe to delete.\r\n"
        . ".\r\n"; # terminating dot per RFC 5321 (no dot-stuffing needed, no line starts with a lone dot above)
    $sock->print($body);
    print "C: <DATA body, subject: $subject>\n";
    my ($sent_code) = read_response($sock);
    print "\n";
    if (defined $sent_code && $sent_code eq '250') {
        print "SUCCESS: message queued for delivery.\n\n";
    } else {
        print "FAIL: message not accepted after DATA (code: " . ($sent_code // 'none') . ")\n\n";
    }
}

send_line($sock, "QUIT");
read_response($sock);
$sock->close;

print "\n=== SUMMARY ===\n";
print "Raw-socket path: " . ($overall_ok ? "SUCCESS via $overall_ok" : 'FAILED for all attempted mechanisms') . "\n";
print "\nRecord this result in issue_tracking/015-dovecot-imap-api.md before\n";
print "writing real _smtp_connect code in Homelab::Mail.\n";
