use strict;
use warnings;
use Test::More;
use Test::Mojo;

unless ($ENV{HOMELAB_SSO_UI_CONFIG}) {
    plan skip_all => 'Set HOMELAB_SSO_UI_CONFIG to run integration tests';
}

use lib 'lib';
use Mojolicious::Commands;

my $t = Test::Mojo->new('Homelab::SsoUI::App');

# Health check — no auth required
$t->get_ok('/health')->status_is(200)->content_is('ok');

# Unknown client_id/redirect_uri is rejected before any login form is shown
$t->get_ok('/oauth/authorize?client_id=nope&redirect_uri=https://evil.example/')
  ->status_is(400)
  ->text_like('.alert-error', qr/Unknown client/i);

# Token endpoint rejects unsupported grant types
$t->post_ok('/oauth/token', form => { grant_type => 'password' })
  ->status_is(400)
  ->json_is('/error', 'unsupported_grant_type');

# Token endpoint rejects an unknown client
$t->post_ok('/oauth/token', form => {
    grant_type    => 'authorization_code',
    code          => 'whatever',
    client_id     => 'nope',
    client_secret => 'nope',
    redirect_uri  => 'https://evil.example/',
})->status_is(401)
  ->json_is('/error', 'invalid_client');

# userinfo requires a bearer token
$t->get_ok('/oauth/userinfo')
  ->status_is(401)
  ->json_is('/error', 'Token required');

# logout with no redirect_uri renders the fallback page
$t->get_ok('/logout')
  ->status_is(200)
  ->text_like('p', qr/logged out/i);

# logout refuses to redirect to an origin that isn't a registered client's
$t->get_ok('/logout?redirect_uri=https://evil.example/steal')
  ->status_is(200)
  ->text_like('p', qr/logged out/i);

done_testing;
