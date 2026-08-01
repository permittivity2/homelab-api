package Homelab::DriveWebUI::Controller::Auth;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::Util qw(secure_compare);

# True if we have a local session AND it hasn't been invalidated by a
# logout that happened somewhere else (Mail, or a future third app) — see
# _session_stale for what "invalidated" means. This is what makes logout
# propagate immediately across apps instead of only affecting whichever
# app you actually clicked logout in.
sub _session_valid ($c) {
    return 0 unless $c->session('jwt');
    if (_session_stale($c)) {
        $c->session(expires => 1);
        return 0;
    }
    return 1;
}

# The IdP (homelab-sso-ui) sets a plain, unsigned "session epoch" marker
# cookie scoped to the shared parent domain (session.cookie_domain in its
# own config) — every request to any consuming app under that domain
# carries it automatically, no extra network call needed. We remember
# which epoch was current when *we* logged in; if the live cookie is now
# missing or different, the shared IdP session ended (logout, anywhere)
# since then, and this local session — even though it's still internally
# "valid" — should be treated as dead. See github-repos/homelab-api
# issue #012.
sub _session_stale ($c) {
    my $ours = $c->session('sso_epoch');
    return 0 unless defined $ours;   # pre-epoch session (e.g. mid-upgrade) — don't force logout
    my $live = $c->cookie('homelab-sso-epoch');
    return !defined($live) || $live ne $ours;
}

# Under bridge: redirect to SSO if no (still-valid) session
sub check ($c) {
    return 1 if _session_valid($c);
    return _redirect_to_sso($c);
}

# GET /login — does triple duty, mirroring Roundcube's own OAuth login
# action: already logged in -> bounce to /drive; a code/state came back
# from the SSO callback -> exchange it; otherwise -> start the SSO dance.
sub login ($c) {
    return $c->redirect_to('/drive') if _session_valid($c);

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
    $c->session(sso_epoch     => $result->{sso_epoch});
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
    # Route through SSO's single-logout endpoint so the *shared* IdP
    # session is cleared too — otherwise landing back on /login would
    # immediately auto-redirect through SSO and silently log the user
    # right back in, since that session would still be alive.
    $c->redirect_to($c->sso->logout_url($c->sso->redirect_uri));
}

1;
