#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'HOMELAB_API_CONFIG not set; skipping integration tests';
}

require Test::Mojo;

my $t = Test::Mojo->new('Homelab::API');

# Get a test token first
my $login = $t->post_ok('/api/v1/auth/login',
    json => { email => 'permittivity@mailmasker.org', password => 'Mcl532vtc896?.' })
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

done_testing();
