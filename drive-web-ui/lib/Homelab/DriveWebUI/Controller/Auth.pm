package Homelab::DriveWebUI::Controller::Auth;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::Util qw(secure_compare);

# Under bridge: redirect to SSO if no session JWT
sub check ($c) {
    return 1 if $c->session('jwt');
    return _redirect_to_sso($c);
}

# GET /login — does triple duty, mirroring Roundcube's own OAuth login
# action: already logged in -> bounce to /drive; a code/state came back
# from the SSO callback -> exchange it; otherwise -> start the SSO dance.
sub login ($c) {
    return $c->redirect_to('/drive') if $c->session('jwt');

    my $code  = $c->param('code');
    my $state = $c->param('state');

    return _redirect_to_sso($c) unless $code;

    my $expected_state = $c->session('oauth_state');
    $c->session(oauth_state => undef);
    unless ($expected_state && $state && secure_compare($expected_state, $state)) {
        return _redirect_to_sso($c);   # forged/stale code — restart the dance
    }

    my $result = $c->sso->exchange_code($code);
    unless ($result->{access_token}) {
        return _redirect_to_sso($c);   # exchange failed — restart the dance
    }

    $c->session(jwt           => $result->{access_token});
    $c->session(refresh_token => $result->{refresh_token});
    $c->redirect_to('/drive');
}

sub _redirect_to_sso ($c) {
    my $state = _random_state();
    $c->session(oauth_state => $state);
    my $url = $c->sso->authorize_url($state);

    if ($c->is_htmx) {
        $c->res->headers->header('HX-Redirect' => $url);
        $c->rendered(200);
    } else {
        $c->redirect_to($url);
    }
    return 0;
}

sub _random_state {
    my @chars = ('a' .. 'z', 'A' .. 'Z', '0' .. '9');
    my $state = '';
    $state .= $chars[int(rand(@chars))] for 1 .. 32;
    return $state;
}

sub logout ($c) {
    eval { $c->api->post('/api/v1/auth/logout', {}) };
    $c->session(expires => 1);
    $c->redirect_to('/login');
}

1;
