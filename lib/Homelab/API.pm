package Homelab::API;

use Mojolicious::Lite -signatures;
use Homelab::Database;
use Homelab::Auth;
use Homelab::RateLimit;
use Homelab::Drive;
use Homelab::Mail;
use Homelab::Roles;
use Homelab::Utils::Password qw(hash_password);
use Homelab::Utils::Passphrase qw(generate_passphrase);
use YAML::XS qw(LoadFile);
use Carp qw(croak);

my $config = LoadFile($ENV{HOMELAB_API_CONFIG} || '/etc/homelab/api/config.yml');
my $db = Homelab::Database->new($config);
my $auth = Homelab::Auth->new($db, $config);
my $limiter = Homelab::RateLimit->new($db);
my $drive = Homelab::Drive->new($db, $config);
my $mail = Homelab::Mail->new($db, $config);
my $roles = Homelab::Roles->new($db, $config);

sub _set_json_response {
    my ($c, $data, $status) = @_;
    $status ||= 200;
    $c->res->headers->content_type('application/json');
    $c->res->code($status);
    $c->render(json => $data);
}

sub _bearer_token {
    my $c = shift;
    my $token;
    if (my $hdr = $c->req->headers->authorization) {
        ($token) = $hdr =~ /^Bearer\s+(.+)$/;
    }
    $token //= $c->cookie('homelab-token');
    return $token;
}

sub _auth_user {
    my $c = shift;
    my $token = _bearer_token($c);
    return undef unless $token;
    my $result = $auth->validate($token);
    return $result->{error} ? undef : $result->{user}{email};
}

# A leaf route's own pattern->unparsed is only its fragment RELATIVE to
# whatever bridge(s) it's registered under (e.g. '/quota', not
# '/api/v1/drive/quota') — walk up the ->parent chain and concatenate every
# ancestor's own pattern to get the full path Mojolicious actually matched.
sub _full_pattern {
    my ($route) = @_;
    my @parts;
    for (my $r = $route; $r; $r = $r->parent) {
        unshift @parts, $r->pattern->unparsed;
    }
    return join('', @parts);
}

# Authenticate + authorize a request against the caller's role permissions.
# Returns the caller's email on success, or undef after having already sent
# a 401/403 response (mirrors _auth_user's "check the return value" idiom).
sub _auth_and_authorize {
    my $c = shift;
    my $email = _auth_user($c);
    unless ($email) {
        _set_json_response($c, { success => 0, error => 'Unauthorized' }, 401);
        return undef;
    }
    my $method  = uc($c->req->method);
    my $pattern = _full_pattern($c->match->endpoint);
    unless ($roles->user_has_permission($email, $method, $pattern)) {
        _set_json_response($c, { success => 0, error => 'Forbidden' }, 403);
        return undef;
    }
    # Stashed for routes (e.g. /api/v1/mail/*) that need the raw JWT itself
    # as a downstream credential, not just the email it resolves to.
    $c->stash(user_jwt => _bearer_token($c));
    return $email;
}

# Recursively walk the app's route tree and return the set of registered
# "METHOD /pattern" strings, used to validate endpoint keys an admin tries
# to grant to a role (rejects typos/dead permissions that could never match).
sub _known_endpoints {
    my @out;
    my $walk = sub {
        my ($routes, $recurse) = @_;
        for my $route (@{ $routes->children }) {
            if (@{ $route->via // [] }) {
                my $pattern = _full_pattern($route);
                push @out, uc($_) . ' ' . $pattern for @{ $route->via };
            }
            $recurse->($route, $recurse);
        }
    };
    $walk->(app->routes, $walk);
    return \@out;
}

hook before_dispatch => sub {
    my $c = shift;
    $c->res->headers->add('Access-Control-Allow-Origin', '*');
    $c->res->headers->add('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    $c->res->headers->add('Access-Control-Allow-Headers', 'Content-Type, Authorization');
};

post '/api/v1/auth/login' => sub ($c) {
    my $json = $c->req->json;

    unless ($json && $json->{email} && $json->{password}) {
        return _set_json_response(
            $c,
            { success => 0, error => 'Email and password required' },
            400
        );
    }

    my $email = $json->{email};

    unless ($limiter->check($email)) {
        return _set_json_response(
            $c,
            { success => 0, error => 'Too many login attempts. Please try again in 15 minutes.' },
            429
        );
    }

    my $result = $auth->login($email, $json->{password});

    if ($result->{error}) {
        $limiter->record_attempt($email);
        return _set_json_response($c, { success => 0, error => $result->{error} }, 401);
    }

    $limiter->clear($email);

    $c->cookie(
        'homelab-token' => $result->{refresh_token},
        {
            path     => '/',
            httponly => 1,
            secure   => $config->{session}{secure} // 0,
            samesite => 'Strict',
            expires  => time + (30 * 24 * 60 * 60),
        }
    );

    return _set_json_response(
        $c,
        {
            success       => 1,
            token         => $result->{token},
            refresh_token => $result->{refresh_token},
            expires_in    => $result->{expires_in},
            user          => $result->{user},
        },
        200
    );
};

# Flat-JSON token introspection for external services that can't parse the
# nested /validate response — Dovecot's oauth2 passdb (introspection_mode =
# auth) and Roundcube's oauth_identity_uri both expect a plain top-level
# attribute (default "email").
get '/api/v1/auth/introspect' => sub ($c) {
    my $auth_header = $c->req->headers->authorization;
    my $token;

    if ($auth_header && $auth_header =~ /^Bearer\s+(.+)$/) {
        $token = $1;
    }

    return _set_json_response($c, { error => 'Token required' }, 401)
        unless $token;

    my $result = $auth->validate($token);
    return _set_json_response($c, { error => $result->{error} }, 401)
        if $result->{error};

    return _set_json_response($c, { email => $result->{user}{email} }, 200);
};

post '/api/v1/auth/logout' => sub ($c) {
    my $refresh_token = $c->cookie('homelab-token');

    unless ($refresh_token) {
        return _set_json_response(
            $c,
            { success => 0, error => 'Refresh token required' },
            401
        );
    }

    # logout/refresh authenticate via the refresh-token cookie itself, not a
    # Bearer JWT (the JWT may already be expired — that's often *why* the
    # client is calling these) — resolve the acting user from the token to
    # run the same permission check the JWT-based routes get.
    my $email = $roles->email_for_refresh_token($refresh_token);
    return _set_json_response($c, { success => 0, error => 'Invalid or expired refresh token' }, 401)
        unless $email;
    return _set_json_response($c, { success => 0, error => 'Forbidden' }, 403)
        unless $roles->user_has_permission($email, 'POST', '/api/v1/auth/logout');

    my $result = $auth->logout($refresh_token);

    if ($result->{error}) {
        return _set_json_response($c, { success => 0, error => $result->{error} }, 500);
    }

    $c->cookie('homelab-token', '', { path => '/', expires => 1 });

    return _set_json_response($c, { success => 1 }, 200);
};

get '/api/v1/auth/validate' => sub ($c) {
    my $email = _auth_and_authorize($c);
    return unless $email;

    return _set_json_response(
        $c,
        { success => 1, valid => 1, user => { email => $email } },
        200
    );
};

post '/api/v1/auth/refresh' => sub ($c) {
    my $refresh_token = $c->cookie('homelab-token');

    unless ($refresh_token) {
        return _set_json_response(
            $c,
            { success => 0, error => 'Refresh token required' },
            401
        );
    }

    my $email = $roles->email_for_refresh_token($refresh_token);
    return _set_json_response($c, { success => 0, error => 'Invalid or expired refresh token' }, 401)
        unless $email;
    return _set_json_response($c, { success => 0, error => 'Forbidden' }, 403)
        unless $roles->user_has_permission($email, 'POST', '/api/v1/auth/refresh');

    my $result = $auth->refresh($refresh_token);

    if ($result->{error}) {
        return _set_json_response($c, { success => 0, error => $result->{error} }, 401);
    }

    $c->cookie(
        'homelab-token' => $result->{refresh_token},
        {
            path     => '/',
            httponly => 1,
            secure   => $config->{session}{secure} // 0,
            samesite => 'Strict',
            expires  => time + (30 * 24 * 60 * 60),
        }
    );

    return _set_json_response(
        $c,
        {
            success       => 1,
            token         => $result->{token},
            refresh_token => $result->{refresh_token},
            expires_in    => $result->{expires_in},
        },
        200
    );
};

# Public share routes (no auth required) — must be before under() bridge

# File share: return metadata as JSON (BFF serves file via X-Accel-Redirect)
get '/api/v1/drive/s/:token/meta' => sub ($c) {
    my $token  = $c->stash('token');
    my $result = $drive->get_shared_file($token);
    return _set_json_response($c, { success => 0, error => $result->{error} }, 404)
        if $result->{error};
    return _set_json_response($c, $result, 200);
};

# Directory share: return dir info + file list as JSON
get '/api/v1/drive/s/:token/dir' => sub ($c) {
    my $token  = $c->stash('token');
    my $result = $drive->get_shared_dir($token);
    return _set_json_response($c, { success => 0, error => $result->{error} }, 404)
        if $result->{error};
    return _set_json_response($c, $result, 200);
};

# Legacy: direct file download via API (kept for backward compat)
get '/api/v1/drive/s/:token' => sub ($c) {
    my $token  = $c->stash('token');
    my $result = $drive->get_shared_file($token);
    return _set_json_response($c, { success => 0, error => $result->{error} }, 404)
        if $result->{error};
    my $disk_path = $drive->_disk_path($result->{user_id}, $result->{uuid});
    return _set_json_response($c, { success => 0, error => 'File not found on disk' }, 404)
        unless -f $disk_path;
    $c->res->headers->content_type($result->{mime_type});
    $c->res->headers->content_disposition("attachment; filename=\"$result->{file_name}\"");
    $c->reply->file($disk_path);
};

get '/api/v1/health' => sub ($c) {
    my $db_status = $db->ping ? 'connected' : 'disconnected';
    my $status = $db_status eq 'connected' ? 'ok' : 'error';

    return _set_json_response(
        $c,
        {
            status   => $status,
            version  => '0.2~beta1',
            database => $db_status,
        },
        $status eq 'ok' ? 200 : 500
    );
};

# Protected Drive routes (requires auth + permission)
my $d = under '/api/v1/drive' => sub ($c) {
    my $email = _auth_and_authorize($c);
    return 0 unless $email;
    $c->stash(user_email => $email);
    return 1;
};

$d->get('/quota' => sub ($c) {
    my $email = $c->stash('user_email');
    my $result = $drive->get_quota($email);
    return _set_json_response($c, $result, $result->{error} ? 401 : 200);
});

$d->post('/fileinfo' => sub ($c) {
    my $email = $c->stash('user_email');
    my $json  = $c->req->json // {};

    my $has_path   = exists $json->{path};
    my $has_dir_id = exists $json->{dir_id};

    if ($has_path && $has_dir_id) {
        return _set_json_response($c,
            { success => 0, error => 'Provide path or dir_id, not both' }, 400);
    }

    my %opts;
    $opts{path}      = $json->{path}      if $has_path;
    $opts{dir_id}    = $json->{dir_id}    if $has_dir_id;
    $opts{startat}   = $json->{startat}   if exists $json->{startat};
    $opts{recursive} = $json->{recursive} if exists $json->{recursive};

    my $result = $drive->fileinfo($email, %opts);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->post('/files' => sub ($c) {
    my $email = $c->stash('user_email');
    my $upload = $c->req->upload('file');
    return _set_json_response($c, { success => 0, error => 'No file uploaded' }, 400) unless $upload;

    my $file_name = $upload->filename;
    my $dir_id = $c->param('dir_id');
    my $size = $upload->size;

    # Content-type is never taken from the client — the processor detects it
    # server-side (content_type task) after upload.
    my $result = $drive->upload($email, $file_name, $dir_id, $upload, $size);
    return _set_json_response($c, $result, $result->{error} ? 400 : 201);
});

$d->get('/files/:id/meta' => sub ($c) {
    my $email      = $c->stash('user_email');
    my $file_id    = $c->stash('id');
    my $version_id = $c->param('version');
    my $result     = $drive->get_file_meta($email, $file_id, $version_id);
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

$d->get('/files/:id' => sub ($c) {
    my $email = $c->stash('user_email');
    my $file_id = $c->stash('id');
    my $version_id = $c->param('version');

    my $result = $drive->download($email, $file_id, $version_id);
    return _set_json_response($c, { success => 0, error => $result->{error} }, 404) if $result->{error};

    $c->res->headers->content_type($result->{mime_type});
    $c->res->headers->content_disposition("attachment; filename=\"$result->{file_name}\"");
    $c->reply->file($result->{disk_path});
});

$d->delete('/files/:id' => sub ($c) {
    my $email   = $c->stash('user_email');
    my $file_id = $c->stash('id');
    my $result  = $drive->queue_delete($email, $file_id);
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

$d->patch('/files/:id' => sub ($c) {
    my $email   = $c->stash('user_email');
    my $file_id = $c->stash('id');
    my $json    = $c->req->json // {};

    my $has_path   = exists $json->{to_path};
    my $has_dir_id = exists $json->{dir_id};

    if ($has_path && $has_dir_id) {
        return _set_json_response($c,
            { success => 0, error => 'Provide to_path or dir_id, not both' }, 400);
    }

    if ($has_path || $has_dir_id) {
        my $dir_id;
        if ($has_path) {
            my $resolved = $drive->resolve_path($email, $json->{to_path});
            return _set_json_response($c,
                { success => 0, error => $resolved->{error} }, 404) if $resolved->{error};
            $dir_id = $resolved->{dir_id};
        } else {
            $dir_id = $json->{dir_id};  # undef/null moves to root
        }
        my $result = $drive->move_file($email, $file_id, $dir_id);
        return _set_json_response($c, $result, $result->{error} ? 404 : 200);
    }

    if ($json->{name}) {
        return _set_json_response($c,
            { success => 0, error => 'Rename not yet implemented' }, 501);
    }

    return _set_json_response($c,
        { success => 0, error => 'Provide to_path, dir_id, or name' }, 400);
});

$d->post('/files/:id/copy' => sub ($c) {
    my $email   = $c->stash('user_email');
    my $file_id = $c->stash('id');
    my $json    = $c->req->json // {};

    my $has_path   = exists $json->{to_path};
    my $has_dir_id = exists $json->{dir_id};

    if ($has_path && $has_dir_id) {
        return _set_json_response($c,
            { success => 0, error => 'Provide to_path or dir_id, not both' }, 400);
    }

    unless ($has_path || $has_dir_id) {
        return _set_json_response($c,
            { success => 0, error => 'Provide to_path or dir_id' }, 400);
    }

    my $dir_id;
    if ($has_path) {
        my $resolved = $drive->resolve_path($email, $json->{to_path});
        return _set_json_response($c,
            { success => 0, error => $resolved->{error} }, 404) if $resolved->{error};
        $dir_id = $resolved->{dir_id};
    } else {
        $dir_id = $json->{dir_id};
    }

    my $result = $drive->copy_file($email, $file_id, $dir_id, $json->{name});
    return _set_json_response($c, $result, $result->{error} ? 400 : 202);
});

$d->get('/files/:id/versions' => sub ($c) {
    my $email = $c->stash('user_email');
    my $file_id = $c->stash('id');
    my $result = $drive->list_versions($email, $file_id);
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

$d->get('/trash' => sub ($c) {
    my $email = $c->stash('user_email');
    my $result = $drive->list_trash($email);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->post('/files/:id/restore' => sub ($c) {
    my $email = $c->stash('user_email');
    my $file_id = $c->stash('id');
    my $result = $drive->restore_file($email, $file_id);
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

$d->delete('/trash' => sub ($c) {
    my $email = $c->stash('user_email');
    my $result = $drive->empty_trash($email);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->get('/directories' => sub ($c) {
    my $email  = $c->stash('user_email');
    my $result = exists $c->req->params->to_hash->{parent_id}
        ? $drive->list_directories($email, $c->param('parent_id'))
        : $drive->list_all_directories($email);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->post('/directories' => sub ($c) {
    my $email     = $c->stash('user_email');
    my $json      = $c->req->json // {};
    return _set_json_response($c, { success => 0, error => 'name required' }, 400)
        unless $json->{name};
    my $result = $drive->create_subdirectory($email, $json->{name}, $json->{parent_id});
    return _set_json_response($c, $result, $result->{error} ? 400 : 201);
});

$d->delete('/directories/:id' => sub ($c) {
    my $email = $c->stash('user_email');
    my $dir_id = $c->stash('id');
    my $result = $drive->delete_directory($email, $dir_id);
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

$d->patch('/directories/:id' => sub ($c) {
    my $email  = $c->stash('user_email');
    my $dir_id = $c->stash('id');
    my $json   = $c->req->json // {};

    my $result;
    if (exists $json->{parent_id}) {
        $result = $drive->move_directory($email, $dir_id, $json->{parent_id});
    } elsif (exists $json->{name} && length($json->{name} // '')) {
        $result = $drive->rename_directory($email, $dir_id, $json->{name});
    } else {
        return _set_json_response($c, { error => 'name or parent_id required' }, 400);
    }
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

$d->post('/files/:id/share' => sub ($c) {
    my $email  = $c->stash('user_email');
    my $json   = $c->req->json // {};
    my $result = $drive->create_share($email,
        file_id    => $c->stash('id') + 0,
        share_with => $json->{share_with},
        permission => $json->{permission} // 'read',
    );
    return _set_json_response($c, $result, $result->{error} ? 400 : 201);
});

$d->post('/directories/:id/share' => sub ($c) {
    my $email  = $c->stash('user_email');
    my $json   = $c->req->json // {};
    my $result = $drive->create_share($email,
        dir_id     => $c->stash('id') + 0,
        share_with => $json->{share_with},
        permission => $json->{permission} // 'read',
    );
    return _set_json_response($c, $result, $result->{error} ? 400 : 201);
});

$d->get('/shares' => sub ($c) {
    my $result = $drive->list_shares($c->stash('user_email'));
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->get('/shares/with-me' => sub ($c) {
    my $result = $drive->list_shares_with_me($c->stash('user_email'));
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->delete('/shares/:id' => sub ($c) {
    my $result = $drive->revoke_share($c->stash('user_email'), $c->stash('id'));
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

my $srv     = $config->{server} // {};
my $host    = $srv->{listen} // $srv->{host} // '0.0.0.0';
my $port    = $srv->{port} // 3000;
my $listen  = ($host =~ m{^https?://}) ? $host : "http://$host:$port";

my %hypnotoad = (
    listen   => [$listen],
    pid_file => '/var/lib/homelab/hypnotoad.pid',
    workers  => $srv->{workers} // 2,
);
$hypnotoad{accepts}             = $srv->{accepts}            if exists $srv->{accepts};
$hypnotoad{clients}             = $srv->{max_clients}         if exists $srv->{max_clients};
$hypnotoad{heartbeat_timeout}   = $srv->{heartbeat_timeout}   if exists $srv->{heartbeat_timeout};

app->config(hypnotoad => \%hypnotoad);

$d->post('/bulk/trash' => sub ($c) {
    my $email       = $c->stash('user_email');
    my $json        = $c->req->json // {};
    my $file_ids    = $json->{file_ids}      // [];
    my $dir_ids     = $json->{dir_ids}       // [];
    my $current_dir = $json->{current_dir_id};
    my $result      = $drive->trash_files($email, $file_ids, $current_dir);
    $drive->delete_directory($email, $_) for @$dir_ids;
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->post('/bulk/restore' => sub ($c) {
    my $email    = $c->stash('user_email');
    my $json     = $c->req->json // {};
    my $file_ids = $json->{file_ids} // [];
    my $dest_dir = $json->{dir_id};   # undef = root
    my $result   = $drive->restore_files($email, $file_ids, $dest_dir);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->get('/trash/dir' => sub ($c) {
    my $email   = $c->stash('user_email');
    my $user_id = $drive->_user_id($email);
    return _set_json_response($c, { error => 'User not found' }, 404) unless $user_id;
    my $trash_id = $drive->find_or_create_trash_dir($user_id);
    return _set_json_response($c, { success => 1, dir_id => $trash_id }, 200);
});

$d->post('/bulk/move' => sub ($c) {
    my $email    = $c->stash('user_email');
    my $json     = $c->req->json // {};
    my $file_ids = $json->{file_ids} // [];
    my $dir_ids  = $json->{dir_ids}  // [];
    my $target   = $json->{dir_id};   # undef = root
    my $result   = $drive->bulk_move($email, $file_ids, $dir_ids, $target);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->post('/bulk/copy' => sub ($c) {
    my $email    = $c->stash('user_email');
    my $json     = $c->req->json // {};
    my $file_ids = $json->{file_ids} // [];
    my $dir_ids  = $json->{dir_ids}  // [];
    my $target   = $json->{dir_id};   # undef = root
    my $result   = $drive->bulk_copy($email, $file_ids, $dir_ids, $target);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$d->post('/zip' => sub ($c) {
    my $email     = $c->stash('user_email');
    my $json      = $c->req->json // {};
    my $file_ids  = $json->{file_ids} // [];
    my $dir_ids   = $json->{dir_ids}  // [];
    my $dest_dir  = $json->{dir_id};   # undef = root; caller passes _currentDir()
    my $result    = $drive->queue_zip($email, $file_ids, $dir_ids, $dest_dir);
    return _set_json_response($c, $result, $result->{error} ? 400 : 202);
});

my $m = under '/api/v1/mail' => sub ($c) {
    my $email = _auth_and_authorize($c);
    return 0 unless $email;
    $c->stash(user_email => $email);
    return 1;
};

$m->get('/status' => sub ($c) {
    my $email = $c->stash('user_email');
    my $jwt   = $c->stash('user_jwt');
    my $result = $mail->get_status($email, $jwt);
    # 502, not 401/500: the caller's JWT is valid (that's how they got past
    # the bridge above) -- a failure here is Dovecot/IMAP not cooperating,
    # a downstream service failure, not an auth or client-input problem.
    return _set_json_response($c, $result, $result->{error} ? 502 : 200);
});

# Admin routes — hardcoded to require the site_admin role, independent of
# the dynamic api.role_permissions table (so a bad table edit can never
# lock every admin out with no recovery path).
my $a = under '/api/v1/admin' => sub ($c) {
    my $email = _auth_user($c);
    unless ($email) {
        _set_json_response($c, { success => 0, error => 'Unauthorized' }, 401);
        return 0;
    }
    unless ($roles->is_site_admin($email)) {
        _set_json_response($c, { success => 0, error => 'Forbidden' }, 403);
        return 0;
    }
    $c->stash(user_email => $email);
    return 1;
};

$a->get('/roles' => sub ($c) {
    my $result = $roles->list_roles;
    return _set_json_response($c, { success => 1, roles => $result }, 200);
});

$a->get('/roles/:role/permissions' => sub ($c) {
    my $result = $roles->list_role_permissions($c->stash('role'));
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

$a->post('/roles/:role/permissions' => sub ($c) {
    my $role     = $c->stash('role');
    my $json     = $c->req->json // {};
    my $endpoint = $json->{endpoint};
    return _set_json_response($c, { success => 0, error => 'endpoint required' }, 400)
        unless $endpoint;

    my $known = _known_endpoints();
    return _set_json_response($c, { success => 0, error => 'Unknown endpoint (no matching registered route)' }, 400)
        unless grep { $_ eq $endpoint } @$known;

    my $result = $roles->grant_endpoint($role, $endpoint, $c->stash('user_email'));
    return _set_json_response($c, $result, $result->{error} ? 400 : 201);
});

$a->delete('/roles/:role/permissions' => sub ($c) {
    my $role     = $c->stash('role');
    my $endpoint = $c->param('endpoint') // ($c->req->json // {})->{endpoint};
    return _set_json_response($c, { success => 0, error => 'endpoint required' }, 400)
        unless $endpoint;

    my $result = $roles->revoke_endpoint($role, $endpoint);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$a->get('/users/#email/roles' => sub ($c) {
    my $target = $c->stash('email');
    return _set_json_response($c, { success => 1, email => $target, roles => $roles->user_roles($target) }, 200);
});

$a->post('/users/#email/roles' => sub ($c) {
    my $target = $c->stash('email');
    my $json   = $c->req->json // {};
    my $role   = $json->{role};
    return _set_json_response($c, { success => 0, error => 'role required' }, 400)
        unless $role;

    my $result = $roles->assign_role($target, $role, $c->stash('user_email'));
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

$a->delete('/users/#email/roles/:role' => sub ($c) {
    my $target = $c->stash('email');
    my $role   = $c->stash('role');

    my $result = $roles->revoke_role($target, $role);
    return _set_json_response($c, $result, $result->{error} ? 400 : 200);
});

# Generates a random server-side passphrase and overwrites the target
# user's password with it — never accepts a client-supplied password. Any
# client-supplied "new_password"-shaped key in the body is ignored outright
# (not even inspected further), so there's no observable signal that
# supplying one might work.
$a->post('/users/#email/reset-password' => sub ($c) {
    my $target  = $c->stash('email');
    my $user_id = $roles->user_id($target);
    return _set_json_response($c, { success => 0, error => 'User not found' }, 404)
        unless $user_id;

    my $plaintext = generate_passphrase(
        wordlist_path => $config->{passphrase}{wordlist_path},
    );
    my $hash = hash_password($plaintext);

    $db->query('UPDATE dovecot.users SET password = ? WHERE id = ?', $hash, $user_id);

    return _set_json_response($c, { success => 1, user => { email => $target }, password => $plaintext }, 200);
});

$a->post('/users/#email/revoke-tokens' => sub ($c) {
    my $target = $c->stash('email');
    my $result = $roles->revoke_all_tokens($target);
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

# Same action as /revoke-tokens under a name that reads better for the
# "kick them out and make them log back in" mental model — both call the
# exact same underlying Roles::revoke_all_tokens.
$a->post('/users/#email/force-relogin' => sub ($c) {
    my $target = $c->stash('email');
    my $result = $roles->revoke_all_tokens($target);
    return _set_json_response($c, $result, $result->{error} ? 404 : 200);
});

# Allow uploads up to 10GB; buffer incoming request body on NFS (not tiny local /tmp)
$ENV{MOJO_MAX_MESSAGE_SIZE} = 10_737_418_240;
$ENV{MOJO_TMPDIR}           = $config->{storage}{drive_path} . '/.tmp';

app->start;

1;
