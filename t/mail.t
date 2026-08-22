#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'HOMELAB_API_CONFIG not set; skipping integration tests';
}

require Test::Mojo;
require IO::Socket::SSL;
require MIME::Base64;
require YAML::XS;

my $t = Test::Mojo->new('Homelab::API');

# --- Test-only raw IMAP helper, deliberately NOT part of Homelab::Mail ---
#
# Phase 3's mutating tests (flags/move/trash/purge/folder ops) must never
# operate on real mail. Homelab::Mail has no APPEND method (out of scope
# for the app itself), so this duplicates just enough of the hand-rolled
# AUTHENTICATE OAUTHBEARER handshake (same approach proven in
# script/experiments/imap-oauthbearer-poc.pl) to APPEND one synthetic
# message the tests then operate on -- kept self-contained here rather
# than exposed as a real app feature.
sub _test_imap_append {
    my ($email, $jwt, $folder, $subject) = @_;
    my $config = YAML::XS::LoadFile($ENV{HOMELAB_API_CONFIG});
    my $host   = $config->{mail}{imap}{host};
    my $port   = $config->{mail}{imap}{port};

    my $sock = IO::Socket::SSL->new(PeerHost => $host, PeerPort => $port)
        or die "connect failed: " . IO::Socket::SSL::errstr() . "\n";
    my $read_line = sub {
        my $l = $sock->getline;
        return undef unless defined $l;
        $l =~ s/\r?\n\z//;
        return $l;
    };
    $read_line->(); # greeting

    my $tag = 'a1';
    my $sasl = "n,a=$email,\x01host=$host\x01port=$port\x01auth=Bearer $jwt\x01\x01";
    $sock->print("$tag AUTHENTICATE OAUTHBEARER " . MIME::Base64::encode_base64($sasl, '') . "\r\n");
    my $resp = $read_line->();
    while (defined $resp && $resp !~ /^\Q$tag\E\s/) { $resp = $read_line->(); }
    die "AUTHENTICATE failed: " . ($resp // 'no response') . "\n"
        unless defined $resp && $resp =~ /^\Q$tag\E OK/i;

    my $body = "Subject: $subject\r\nFrom: test\@example.com\r\n"
        . "Date: " . localtime() . "\r\n\r\nSynthetic test message body.\r\n";
    my $n = length($body);
    $sock->print(qq{a2 APPEND "$folder" {$n}\r\n});
    my $cont = $read_line->();
    die "APPEND not accepted: " . ($cont // 'no response') . "\n" unless defined $cont && $cont =~ /^\+/;
    $sock->print($body);
    $sock->print("\r\n");
    $resp = $read_line->();
    while (defined $resp && $resp !~ /^a2\s/) { $resp = $read_line->(); }
    die "APPEND failed: " . ($resp // 'no response') . "\n" unless defined $resp && $resp =~ /^a2 OK/i;

    $sock->print("a3 LOGOUT\r\n");
    $sock->close;
    return 1;
}

my $TEST_EMAIL = 'permittivity@mailmasker.org';

# Get a test token first
my $login = $t->post_ok('/api/v1/auth/login',
    json => { email => $TEST_EMAIL, password => 'Mcl532vtc896?.' })
    ->status_is(200)
    ->json_is('/success', 1);

my $token = $login->tx->res->json->{token};
ok($token, 'Got JWT token');

subtest 'mail status' => sub {
    $t->get_ok('/api/v1/mail/status',
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1);

    my $result = $t->tx->res->json;
    ok(defined $result->{unseen}, 'has unseen count');
    ok(defined $result->{messages}, 'has total message count');
};

subtest 'mail folders' => sub {
    $t->get_ok('/api/v1/mail/folders',
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1);

    my $folders = $t->tx->res->json->{folders};
    ok(ref $folders eq 'ARRAY' && @$folders, 'at least one folder returned');
    ok((grep { $_->{name} eq 'INBOX' } @$folders), 'INBOX is in the folder list');
};

my $first_uid;

subtest 'mail list messages' => sub {
    $t->get_ok('/api/v1/mail/messages?folder=INBOX&limit=2',
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1)
        ->json_is('/folder', 'INBOX')
        ->json_is('/limit', 2);

    my $result = $t->tx->res->json;
    ok(defined $result->{total}, 'has total count');
    ok(ref $result->{messages} eq 'ARRAY', 'messages is an array');
    ok(@{ $result->{messages} } <= 2, 'limit is respected');

    if (@{ $result->{messages} }) {
        $first_uid = $result->{messages}[0]{uid};
        ok($first_uid, 'first message has a uid');
        ok(exists $result->{messages}[0]{subject}, 'message has a subject field');
        ok(exists $result->{messages}[0]{from}, 'message has a from field');
    }

    # Nonexistent folder -> 404, not a generic 502.
    $t->get_ok('/api/v1/mail/messages?folder=INBOX.DoesNotExist12345',
        { Authorization => "Bearer $token" })
        ->status_is(404);
};

subtest 'mail get message and part' => sub {
    plan skip_all => 'no messages in INBOX to fetch' unless $first_uid;

    $t->get_ok("/api/v1/mail/messages/$first_uid?folder=INBOX",
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1);

    my $msg = $t->tx->res->json;
    ok(ref $msg->{headers} eq 'HASH', 'headers is a hash');
    ok(ref $msg->{parts} eq 'ARRAY' && @{ $msg->{parts} }, 'parts is a non-empty array');
    ok(exists $msg->{headers}{subject}, 'headers has subject');

    ok(defined $msg->{rawheaderb64} && length $msg->{rawheaderb64}, 'rawheaderb64 present and non-empty');
    require MIME::Base64;
    my $decoded = MIME::Base64::decode_base64($msg->{rawheaderb64});
    like($decoded, qr/^Subject:/im, 'decoded rawheaderb64 looks like a real header block');

    my ($text_part) = grep { $_->{content_type} =~ m{^text/} } @{ $msg->{parts} };
    if ($text_part) {
        $t->get_ok("/api/v1/mail/messages/$first_uid/part?folder=INBOX&part=$text_part->{part_number}",
            { Authorization => "Bearer $token" })
            ->status_is(200);
        like($t->tx->res->headers->content_type, qr{^text/}, 'part response Content-Type is text/*');
        ok(length($t->tx->res->body) > 0, 'part response has content');
    }

    # Bad part number on a real message -> 404, not 502.
    $t->get_ok("/api/v1/mail/messages/$first_uid/part?folder=INBOX&part=99.99",
        { Authorization => "Bearer $token" })
        ->status_is(404);

    # Malformed part syntax -> 400.
    $t->get_ok("/api/v1/mail/messages/$first_uid/part?folder=INBOX&part=not-a-number",
        { Authorization => "Bearer $token" })
        ->status_is(400);
};

# --- Phase 3: mutating operations -----------------------------------------
# Every mutating test below operates ONLY on synthetic messages/folders
# created by the test itself -- never on real INBOX content. Teardown at
# the bottom removes the test folders even if an earlier assertion fails.

my $TF1 = 'zzhomelabtest1';
my $TF2 = 'zzhomelabtest2';
my $TF3 = 'zzhomelabtest3';
my $SUBJECT = "[homelab-api test message] $$ " . time();


subtest 'mail folder create/rename/delete (synthetic only)' => sub {
    $t->post_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" }, json => { name => $TF1 })
        ->status_is(200)->json_is('/success', 1);
    $t->post_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" }, json => { name => $TF2 })
        ->status_is(200);
    $t->post_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" }, json => { name => $TF3 })
        ->status_is(200);

    # Duplicate create -> 400, not a generic 502.
    $t->post_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" }, json => { name => $TF1 })
        ->status_is(400);

    $t->patch_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" },
        json => { name => $TF3, to => "${TF3}-renamed" })
        ->status_is(200)->json_is('/folder', "${TF3}-renamed");

    $t->delete_ok("/api/v1/mail/folders?name=${TF3}-renamed", { Authorization => "Bearer $token" })
        ->status_is(200);
};

subtest 'mail protected-folder refusal is actually enforced' => sub {
    $t->patch_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" },
        json => { name => 'INBOX', to => 'ShouldNeverHappen' })
        ->status_is(403);

    # Confirm INBOX still exists and nothing named ShouldNeverHappen appeared --
    # verifying the refusal was actually enforced, not just that an error
    # string came back.
    $t->get_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" })->status_is(200);
    my $folders = $t->tx->res->json->{folders};
    ok((grep { $_->{name} eq 'INBOX' } @$folders), 'INBOX still exists');
    ok(!(grep { $_->{name} eq 'ShouldNeverHappen' } @$folders), 'rename did not actually happen');

    my ($trash_folder) = grep { grep { /^\\Trash$/i } @{ $_->{special_use} || [] } } @$folders;
  SKIP: {
        skip 'no \\Trash folder on this account', 2 unless $trash_folder;
        $t->delete_ok("/api/v1/mail/folders?name=$trash_folder->{name}", { Authorization => "Bearer $token" })
            ->status_is(403);
        $t->get_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" })->status_is(200);
        ok((grep { $_->{name} eq $trash_folder->{name} } @{ $t->tx->res->json->{folders} }),
            'Trash folder still exists after refused delete');
    }
};

my $synthetic_uid;

subtest 'mail append synthetic message, flags, move, search' => sub {
    $t->post_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" }, json => { name => $TF1 });
    $t->post_ok('/api/v1/mail/folders', { Authorization => "Bearer $token" }, json => { name => $TF2 });

    eval { _test_imap_append($TEST_EMAIL, $token, $TF1, $SUBJECT) };
    plan skip_all => "APPEND failed, skipping mutation tests: $@" if $@;

    $t->get_ok("/api/v1/mail/search?folder=$TF1&subject=" . _url_encode($SUBJECT),
        { Authorization => "Bearer $token" })
        ->status_is(200)->json_is('/success', 1);
    my $hits = $t->tx->res->json->{messages};
    is(scalar @$hits, 1, 'search finds exactly the synthetic message');
    $synthetic_uid = $hits->[0]{uid};
    ok($synthetic_uid, 'synthetic message has a uid');

    # Flags: set \Flagged, verify, then revert.
    $t->post_ok("/api/v1/mail/messages/$synthetic_uid/flags?folder=$TF1", { Authorization => "Bearer $token" },
        json => { add => ['\\Flagged'] })
        ->status_is(200);
    ok((grep { $_ eq '\\Flagged' } @{ $t->tx->res->json->{flags} }), '\\Flagged set');

    $t->post_ok("/api/v1/mail/messages/$synthetic_uid/flags?folder=$TF1", { Authorization => "Bearer $token" },
        json => { remove => ['\\Flagged'] })
        ->status_is(200);
    ok(!(grep { $_ eq '\\Flagged' } @{ $t->tx->res->json->{flags} }), '\\Flagged reverted');

    # Bad flag syntax -> 400.
    $t->post_ok("/api/v1/mail/messages/$synthetic_uid/flags?folder=$TF1", { Authorization => "Bearer $token" },
        json => { add => ['; DROP TABLE'] })
        ->status_is(400);

    # Move between the two test folders. UIDs are per-mailbox, so the
    # message's UID in the destination is generally NOT $synthetic_uid --
    # move_message/the /move route report the real new UID (via the
    # UIDPLUS COPYUID response), which every step from here on must use.
    my $pre_move_uid = $synthetic_uid;
    $t->post_ok("/api/v1/mail/messages/$synthetic_uid/move", { Authorization => "Bearer $token" },
        json => { folder => $TF1, to => $TF2 })
        ->status_is(200)->json_is('/folder', $TF2);
    my $moved = $t->tx->res->json;
    ok(defined $moved->{uid}, 'move reports the message\'s new UID in the destination folder');
    $synthetic_uid = $moved->{uid};

    $t->get_ok("/api/v1/mail/messages/$synthetic_uid?folder=$TF2", { Authorization => "Bearer $token" })
        ->status_is(200);
    $t->get_ok("/api/v1/mail/messages/$pre_move_uid?folder=$TF1", { Authorization => "Bearer $token" })
        ->status_is(404); # gone from the source folder
};

subtest 'mail trash (soft) then purge (hard, Trash-only) the synthetic message' => sub {
    plan skip_all => 'no synthetic message to trash/purge' unless $synthetic_uid;

    # expunge_message must refuse a UID that's NOT in Trash yet.
    $t->delete_ok("/api/v1/mail/messages/$synthetic_uid/permanent", { Authorization => "Bearer $token" })
        ->status_is(404);

    $t->delete_ok("/api/v1/mail/messages/$synthetic_uid?folder=$TF2", { Authorization => "Bearer $token" })
        ->status_is(200);
    my $trashed = $t->tx->res->json;
    my $trash_folder = $trashed->{trash_folder};
    ok($trash_folder, 'delete_message reports the resolved trash folder');
    ok(defined $trashed->{uid}, 'delete_message reports the message\'s new UID in Trash');
    $synthetic_uid = $trashed->{uid}; # UID changed again -- moving into Trash is still a MOVE

    # Already-in-Trash delete attempt -> 400.
    $t->delete_ok("/api/v1/mail/messages/$synthetic_uid?folder=$trash_folder", { Authorization => "Bearer $token" })
        ->status_is(400);

    # Permanent purge -- the one genuinely irreversible step, on a message
    # this test created itself seconds ago.
    $t->delete_ok("/api/v1/mail/messages/$synthetic_uid/permanent", { Authorization => "Bearer $token" })
        ->status_is(200)->json_is('/trash_folder', $trash_folder);

    # Confirm it's actually gone.
    $t->get_ok("/api/v1/mail/messages/$synthetic_uid?folder=$trash_folder", { Authorization => "Bearer $token" })
        ->status_is(404);
};

# Runs unconditionally regardless of whether earlier subtests found
# anything to clean up (each delete is a no-op 404 if the folder was
# never created, which is fine -- not asserted here).
subtest 'teardown: remove any leftover test folders' => sub {
    for my $f ($TF1, $TF2, $TF3, "${TF3}-renamed") {
        $t->delete_ok("/api/v1/mail/folders?name=$f", { Authorization => "Bearer $token" });
    }
};

sub _url_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

done_testing();
