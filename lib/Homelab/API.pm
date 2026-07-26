package Homelab::API;

use Mojolicious::Lite -signatures;
use Homelab::Database;
use Homelab::Auth;
use Homelab::RateLimit;
use Homelab::Drive;
use YAML::XS qw(LoadFile);
use Carp qw(croak);

my $config = LoadFile($ENV{HOMELAB_API_CONFIG} || '/etc/homelab/api/config.yml');
my $db = Homelab::Database->new($config);
my $auth = Homelab::Auth->new($db, $config);
my $limiter = Homelab::RateLimit->new($db);
my $drive = Homelab::Drive->new($db, $config);

sub _set_json_response {
    my ($c, $data, $status) = @_;
    $status ||= 200;
    $c->res->headers->content_type('application/json');
    $c->res->code($status);
    $c->render(json => $data);
}

sub _auth_user {
    my $c = shift;
    my $token;
    if (my $hdr = $c->req->headers->authorization) {
        ($token) = $hdr =~ /^Bearer\s+(.+)$/;
    }
    $token //= $c->cookie('homelab-token');
    return undef unless $token;
    my $result = $auth->validate($token);
    return $result->{error} ? undef : $result->{user}{email};
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

post '/api/v1/auth/logout' => sub ($c) {
    my $refresh_token = $c->cookie('homelab-token');

    unless ($refresh_token) {
        return _set_json_response(
            $c,
            { success => 0, error => 'Refresh token required' },
            401
        );
    }

    my $result = $auth->logout($refresh_token);

    if ($result->{error}) {
        return _set_json_response($c, { success => 0, error => $result->{error} }, 500);
    }

    $c->cookie('homelab-token', '', { path => '/', expires => 1 });

    return _set_json_response($c, { success => 1 }, 200);
};

get '/api/v1/auth/validate' => sub ($c) {
    my $auth_header = $c->req->headers->authorization;
    my $token;

    if ($auth_header && $auth_header =~ /^Bearer\s+(.+)$/) {
        $token = $1;
    }

    unless ($token) {
        return _set_json_response(
            $c,
            { success => 0, error => 'Token required' },
            401
        );
    }

    my $result = $auth->validate($token);

    if ($result->{error}) {
        return _set_json_response($c, { success => 0, error => $result->{error} }, 401);
    }

    return _set_json_response(
        $c,
        { success => 1, valid => 1, user => $result->{user} },
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

# Protected Drive routes (requires auth)
my $d = under '/api/v1/drive' => sub ($c) {
    my $email = _auth_user($c);
    unless ($email) {
        _set_json_response($c, { success => 0, error => 'Unauthorized' }, 401);
        return 0;
    }
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
    my $mime = $upload->headers->content_type // 'application/octet-stream';
    my $size = $upload->size;

    my $result = $drive->upload($email, $file_name, $dir_id, $upload, $size, $mime);
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

$d->post('/zip' => sub ($c) {
    my $email     = $c->stash('user_email');
    my $json      = $c->req->json // {};
    my $file_ids  = $json->{file_ids} // [];
    my $dir_ids   = $json->{dir_ids}  // [];
    my $dest_dir  = $json->{dir_id};   # undef = root; caller passes _currentDir()
    my $result    = $drive->queue_zip($email, $file_ids, $dir_ids, $dest_dir);
    return _set_json_response($c, $result, $result->{error} ? 400 : 202);
});

# Allow uploads up to 10GB; buffer incoming request body on NFS (not tiny local /tmp)
$ENV{MOJO_MAX_MESSAGE_SIZE} = 10_737_418_240;
$ENV{MOJO_TMPDIR}           = $config->{storage}{drive_path} . '/.tmp';

app->start;

1;
