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

# Mints a one-time code for the given tokens and redirects the browser back
# to the client with it — shared by both the "already has an IdP session"
# fast path and the "just typed a password" path.
sub _issue_code_and_redirect ($c, $client_id, $redirect_uri, $state, $jwt, $refresh_token, $expires_in) {
    _purge_expired();
    my $code = _random_code();
    $codes{$code} = {
        jwt           => $jwt,
        refresh_token => $refresh_token,
        expires_in    => $expires_in,
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
            );
        }

        # JWT's expired/invalid — try a silent refresh before giving up.
        if (my $refresh_token = $c->session('refresh_token')) {
            my $result = $c->api->refresh($refresh_token);
            if ($result->{success}) {
                _establish_session($c, $result->{token}, $result->{refresh_token}, $c->session('email'));
                return _issue_code_and_redirect(
                    $c, $client_id, $redirect_uri, $state,
                    $result->{token}, $result->{refresh_token}, $result->{expires_in},
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
    _issue_code_and_redirect(
        $c, $client_id, $redirect_uri, $state,
        $result->{token}, $result->{refresh_token}, $result->{expires_in},
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

1;
