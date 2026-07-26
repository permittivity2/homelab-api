package Homelab::DriveWebUI::Controller::Auth;

use Mojo::Base 'Mojolicious::Controller', -signatures;

# Under bridge: redirect to login if no session JWT
sub check ($c) {
    return 1 if $c->session('jwt');
    if ($c->is_htmx) {
        $c->res->headers->header('HX-Redirect' => '/login');
        $c->rendered(200);
    } else {
        $c->redirect_to('/login');
    }
    return 0;
}

sub login_form ($c) {
    return $c->redirect_to('/drive') if $c->session('jwt');
    $c->render(template => 'auth/login', layout => 'login', error => undef);
}

sub login ($c) {
    my $email    = $c->param('email')    // '';
    my $password = $c->param('password') // '';

    unless ($email && $password) {
        return $c->render(
            template => 'auth/login',
            layout   => 'login',
            error    => 'Email and password are required.',
        );
    }

    my $result = $c->api->post('/api/v1/auth/login', {
        email    => $email,
        password => $password,
    });

    if ($result->{success}) {
        $c->session(jwt           => $result->{token});
        $c->session(refresh_token => $result->{refresh_token});
        $c->session(email         => $result->{user}{email} // $email);
        return $c->redirect_to('/drive');
    }

    my $msg = $result->{_status} == 429
        ? 'Too many login attempts. Please wait 15 minutes.'
        : ($result->{error} // 'Login failed. Check your email and password.');

    $c->render(
        template => 'auth/login',
        layout   => 'login',
        error    => $msg,
    );
}

sub logout ($c) {
    eval { $c->api->post('/api/v1/auth/logout', {}) };
    $c->session(expires => 1);
    $c->redirect_to('/login');
}

1;
