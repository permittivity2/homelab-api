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
    json => { email => 'permittivity@example.com', password => 'Mcl532vtc896?.' })
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

done_testing();
