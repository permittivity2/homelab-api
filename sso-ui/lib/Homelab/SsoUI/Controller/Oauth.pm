package Homelab::SsoUI::Controller::Oauth;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::URL;
use Mojo::Util qw(secure_compare);
use Mojo::JSON qw(decode_json);
use MIME::Base64 qw(decode_base64);

# One-time authorization codes, keyed by code: { jwt, refresh_token,
# client_id, redirect_uri, expires_at }. In-process only — the config's
# `server.workers` must stay at 1 unless this is replaced with a shared
# store, since a code minted by one worker wouldn't be visible to another.
my %codes;

use constant CODE_TTL => 60;

sub _find_client ($c, $client_id) {
    return undef unless defined $client_id;
    for my $client (@{ $c->oauth_clients }) {
        return $client if $client->{client_id} eq $client_id;
    }
    return undef;
}

sub _random_code {
    my @chars = ('a' .. 'z', 'A' .. 'Z', '0' .. '9');
    my $code = '';
    $code .= $chars[int(rand(@chars))] for 1 .. 48;
    return $code;
}

# Reads the `exp` claim straight out of a JWT's payload segment, with no
# signature verification — only used after homelab-api's own introspect
# call has already confirmed the token is currently valid, purely to give
# the client an accurate expires_in instead of leaving it blank.
sub _jwt_expires_in ($jwt) {
    my (undef, $payload_b64) = split /\./, $jwt, 3;
    return undef unless $payload_b64;
    $payload_b64 =~ tr{-_}{+/};
    $payload_b64 .= '=' x ((4 - length($payload_b64) % 4) % 4);
    my $payload = eval { decode_json(decode_base64($payload_b64)) };
    return undef unless $payload && $payload->{exp};
    my $remaining = $payload->{exp} - time;
    return $remaining > 0 ? $remaining : undef;
}

sub _purge_expired {
    my $now = time;
    delete $codes{$_} for grep { $codes{$_}{expires_at} < $now } keys %codes;
}

use constant EPOCH_COOKIE => 'homelab-sso-epoch';

# Sets the cross-app "session epoch" cookie — a plain, unsigned opaque
# marker, deliberately scoped wider than this app (session.cookie_domain,
# e.g. "mailmasker.org") so every consuming app under that domain can see
# it appear/disappear on the very next request, with no extra network
# call. It's not a bearer credential: possessing/forging it grants no
# access on its own, since each app still needs its own real
# jwt/refresh_token. See github-repos/homelab-api issue #012.
sub _set_epoch_cookie ($c, $epoch) {
    my $domain = $c->app->config->{session}{cookie_domain};
    $c->cookie(EPOCH_COOKIE, $epoch, {
        ($domain ? (domain => $domain) : ()),
        path     => '/',
        secure   => $c->app->config->{session}{secure} // 1,
        httponly => 1,
        samesite => 'Lax',
        expires  => time + ($c->app->config->{session}{expiry} // 30 * 24 * 60 * 60),
    });
}

sub _clear_epoch_cookie ($c) {
    my $domain = $c->app->config->{session}{cookie_domain};
    $c->cookie(EPOCH_COOKIE, '', {
        ($domain ? (domain => $domain) : ()),
        path    => '/',
        expires => 1,
    });
}

# Is the given URL's origin (scheme+host+port) one of our registered
# clients' redirect_uri origins? Looser than the OAuth redirect_uri check
# (which requires an exact match) — a sensible post-logout landing page
# reasonably differs in path from the OAuth callback path (e.g.
# Roundcube's callback is /index.php?... but its post-logout target is
# just /). This is what stands between /logout and being an open redirect.
sub _origin_allowed ($c, $url) {
    my $target = Mojo::URL->new($url);
    return 0 unless $target->scheme && $target->host;
    for my $client (@{ $c->oauth_clients }) {
        my $reg = Mojo::URL->new($client->{redirect_uri});
        return 1 if $reg->scheme eq $target->scheme
            && $reg->host eq $target->host
            && ($reg->port // '') eq ($target->port // '');
    }
    return 0;
}

# Mints a one-time code for the given tokens and redirects the browser back
# to the client with it — shared by both the "already has an IdP session"
# fast path and the "just typed a password" path.
sub _issue_code_and_redirect ($c, $client_id, $redirect_uri, $state, $jwt, $refresh_token, $expires_in, $sso_epoch) {
    _purge_expired();
    my $code = _random_code();
    $codes{$code} = {
        jwt           => $jwt,
        refresh_token => $refresh_token,
        expires_in    => $expires_in,
        sso_epoch     => $sso_epoch,
        client_id     => $client_id,
        redirect_uri  => $redirect_uri,
        expires_at    => time + CODE_TTL,
    };

    my $target = Mojo::URL->new($redirect_uri);
    $target->query->append(code => $code, state => $state);
    $c->redirect_to($target);
}

# Establishes (or refreshes) the IdP session — not scoped to any one
# client, since a valid session should let a request for *any* registered
# client skip the login form. This is what makes it real SSO instead of a
# per-app login.
sub _establish_session ($c, $jwt, $refresh_token, $email) {
    $c->session(jwt => $jwt, refresh_token => $refresh_token, email => $email);
}

# Starts a brand new "session epoch" — called only on a genuine
# credential-based login, never on a silent token refresh (the epoch
# represents the session's identity, not its current token; regenerating
# it on every refresh would make every consuming app think the session
# changed and force a needless re-login).
sub _start_new_epoch ($c) {
    my $epoch = _random_code();
    $c->session(sso_epoch => $epoch);
    _set_epoch_cookie($c, $epoch);
    return $epoch;
}

# GET /oauth/authorize?response_type=code&client_id=...&redirect_uri=...&state=...
sub authorize ($c) {
    my $client_id    = $c->param('client_id');
    my $redirect_uri = $c->param('redirect_uri');
    my $state        = $c->param('state') // '';

    my $client = _find_client($c, $client_id);
    unless ($client && $redirect_uri && $client->{redirect_uri} eq $redirect_uri) {
        return $c->render(
            template => 'oauth/error',
            layout   => 'login',
            status   => 400,
            message  => 'Unknown client or redirect_uri.',
        );
    }

    # Already have a live IdP session? Skip the form entirely.
    if (my $jwt = $c->session('jwt')) {
        my $info = $c->api->introspect($jwt);
        if ($info->{email}) {
            return _issue_code_and_redirect(
                $c, $client_id, $redirect_uri, $state,
                $jwt, $c->session('refresh_token'), _jwt_expires_in($jwt),
                $c->session('sso_epoch'),
            );
        }

        # JWT's expired/invalid — try a silent refresh before giving up.
        # The epoch is deliberately left unchanged — this is the same
        # logical session continuing, not a new one.
        if (my $refresh_token = $c->session('refresh_token')) {
            my $result = $c->api->refresh($refresh_token);
            if ($result->{success}) {
                _establish_session($c, $result->{token}, $result->{refresh_token}, $c->session('email'));
                return _issue_code_and_redirect(
                    $c, $client_id, $redirect_uri, $state,
                    $result->{token}, $result->{refresh_token}, $result->{expires_in},
                    $c->session('sso_epoch'),
                );
            }
        }

        # Both the JWT and the refresh attempt failed — the session is
        # dead, clear it so we don't keep retrying it on every request.
        $c->session(expires => 1);
    }

    $c->render(
        template     => 'oauth/login',
        layout       => 'login',
        error        => undef,
        client_id    => $client_id,
        redirect_uri => $redirect_uri,
        state        => $state,
    );
}

# POST /oauth/authorize — credential submission
sub authorize_submit ($c) {
    my $client_id    = $c->param('client_id');
    my $redirect_uri = $c->param('redirect_uri');
    my $state        = $c->param('state') // '';
    my $email        = $c->param('email')    // '';
    my $password     = $c->param('password') // '';

    my $client = _find_client($c, $client_id);
    unless ($client && $redirect_uri && $client->{redirect_uri} eq $redirect_uri) {
        return $c->render(
            template => 'oauth/error',
            layout   => 'login',
            status   => 400,
            message  => 'Unknown client or redirect_uri.',
        );
    }

    my $render_form_error = sub ($msg) {
        $c->render(
            template     => 'oauth/login',
            layout       => 'login',
            error        => $msg,
            client_id    => $client_id,
            redirect_uri => $redirect_uri,
            state        => $state,
        );
    };

    return $render_form_error->('Email and password are required.')
        unless $email && $password;

    my $result = $c->api->login($email, $password);
    unless ($result->{success}) {
        my $msg = ($result->{_status} // 0) == 429
            ? 'Too many login attempts. Please wait 15 minutes.'
            : ($result->{error} // 'Login failed. Check your email and password.');
        return $render_form_error->($msg);
    }

    _establish_session($c, $result->{token}, $result->{refresh_token}, $email);
    my $epoch = _start_new_epoch($c);
    _issue_code_and_redirect(
        $c, $client_id, $redirect_uri, $state,
        $result->{token}, $result->{refresh_token}, $result->{expires_in},
        $epoch,
    );
}

# POST /oauth/token — server-to-server code exchange
sub token ($c) {
    my $grant_type    = $c->param('grant_type')    // '';
    my $code          = $c->param('code')          // '';
    my $client_id     = $c->param('client_id')     // '';
    my $client_secret = $c->param('client_secret') // '';
    my $redirect_uri  = $c->param('redirect_uri')  // '';

    return $c->render(json => { error => 'unsupported_grant_type' }, status => 400)
        unless $grant_type eq 'authorization_code';

    my $client = _find_client($c, $client_id);
    return $c->render(json => { error => 'invalid_client' }, status => 401)
        unless $client && secure_compare($client->{client_secret}, $client_secret);

    _purge_expired();
    my $entry = delete $codes{$code};   # one-time use
    unless ($entry
        && $entry->{client_id} eq $client_id
        && $entry->{redirect_uri} eq $redirect_uri
        && $entry->{expires_at} >= time)
    {
        return $c->render(json => { error => 'invalid_grant' }, status => 400);
    }

    return $c->render(json => {
        access_token  => $entry->{jwt},
        refresh_token => $entry->{refresh_token},
        token_type    => 'Bearer',
        expires_in    => $entry->{expires_in},
        sso_epoch     => $entry->{sso_epoch},
    });
}

# GET /oauth/userinfo — Bearer-auth passthrough to homelab-api's introspect endpoint
sub userinfo ($c) {
    my $auth_header = $c->req->headers->authorization // '';
    my ($jwt) = $auth_header =~ /^Bearer\s+(.+)$/;

    return $c->render(json => { error => 'Token required' }, status => 401)
        unless $jwt;

    my $result = $c->api->introspect($jwt);
    my $status = delete $result->{_status} // 401;
    return $c->render(json => $result, status => $status);
}

# GET /logout?redirect_uri=... — single logout. Clears the IdP session
# (which is what actually matters: without it, both consuming apps'
# auto-redirect-on-unauthenticated behavior would otherwise silently log
# the user right back in) and best-effort revokes whichever refresh token
# was cached in it.
sub logout ($c) {
    if (my $refresh_token = $c->session('refresh_token')) {
        eval { $c->api->revoke($refresh_token) };
    }
    $c->session(expires => 1);
    # Clears the cross-app epoch cookie — this is what makes logout
    # propagate immediately to every other app under the shared domain,
    # not just this one, on their very next request.
    _clear_epoch_cookie($c);

    my $redirect_uri = $c->param('redirect_uri');
    if ($redirect_uri && _origin_allowed($c, $redirect_uri)) {
        return $c->redirect_to($redirect_uri);
    }

    $c->render(template => 'oauth/logged_out', layout => 'login');
}

1;
