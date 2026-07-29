package Homelab::DriveWebUI::Controller::Files;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Scalar::Util qw(looks_like_number);

sub browser ($c) {
    my $meta = $c->api->get('/api/v1/drive/trash/dir');
    $c->stash(trash_dir_id => $meta->{dir_id});
    $c->render(template => 'files/browser', layout => 'default');
}

sub file_rows ($c) {
    my $dir_id  = $c->param('dir_id');
    my $startat = $c->param('startat') // 0;

    $dir_id = undef unless defined $dir_id && looks_like_number($dir_id);

    my %body = (startat => $startat + 0);
    $body{dir_id} = $dir_id + 0 if defined $dir_id;

    my $result = $c->api->post('/api/v1/drive/fileinfo', \%body);

    if (!$result->{success}) {
        return $c->render(
            template => 'shared/_error',
            layout   => undef,
            error    => $result->{error} // 'Failed to load files',
        );
    }

    # Directories only on first page — they're not paginated
    my $dirs = [];
    if ($startat == 0) {
        my $dir_result = $c->api->get('/api/v1/drive/directories');
        my $all_dirs   = $dir_result->{directories} // [];
        $dirs = [grep {
            my $p = $_->{parent_id};
            defined $dir_id ? (defined $p && $p == $dir_id) : !defined $p;
        } @$all_dirs];
    }

    # fileinfo returns 'files' for root (Case A) or 'items' mixing dirs+files for subdirs (Case B).
    # Dirs are already handled via the /drive/directories endpoint, so extract file items only.
    my $raw   = $result->{files} // $result->{items} // [];
    my $files = [grep { ($_->{type} // 'file') ne 'directory' } @$raw];

    # Total file count: Case A provides a server-side total; Case B does not.
    # The API uses PAGE=1000, so all files for a given dir fit in one response — use
    # the filtered count directly. Load More only appears when startat > 0 and there are more.
    my $total = exists $result->{files}
        ? ($result->{total} // scalar @$files)   # Case A: accurate server-side total
        : scalar @$files;                          # Case B: count what was returned

    # Build breadcrumb path for OOB swap
    my $breadcrumb = _build_breadcrumb($c, $dir_id);

    $c->render(
        template    => 'files/_file_rows',
        layout      => undef,
        dirs        => $dirs,
        files       => $files,
        dir_id      => $dir_id,
        startat     => $startat + 0,
        show_dirs   => ($startat == 0 ? 1 : 0),
        total       => $total,
        breadcrumb  => $breadcrumb,
    );
}

sub breadcrumb ($c) {
    my $dir_id = $c->param('dir_id');
    $dir_id = undef unless defined $dir_id && looks_like_number($dir_id);
    my $crumbs = _build_breadcrumb($c, $dir_id);
    $c->render(template => 'files/_breadcrumb', layout => undef, breadcrumb => $crumbs, dir_id => $dir_id);
}

sub quota_bar ($c) {
    my $result = $c->api->get('/api/v1/drive/quota');
    $c->render(template => 'files/_quota_bar', layout => undef, quota => $result);
}

sub upload ($c) {
    my $upload = $c->req->upload('file');
    my $dir_id = $c->param('dir_id');
    $c->app->log->info("UPLOAD dir_id=" . ($dir_id // 'NULL') . " file=" . ($upload ? $upload->filename : 'none'));

    unless ($upload) {
        return $c->render(
            status   => 400,
            template => 'files/_upload_result',
            layout   => undef,
            success  => 0,
            error    => 'No file received',
            filename => undef,
        );
    }

    my %form = (
        file => {
            file     => $upload->asset,
            filename => $upload->filename,
            'Content-Type' => $upload->headers->content_type // 'application/octet-stream',
        },
    );
    $form{dir_id} = $dir_id if defined $dir_id && looks_like_number($dir_id);

    my $result = $c->api->post_form('/api/v1/drive/files', \%form);

    if ($result->{success}) {
        # HX-Trigger tells the file list to refresh
        $c->res->headers->header('HX-Trigger' => 'fileUploaded');
    }

    $c->render(
        status   => $result->{success} ? 200 : ($result->{_status} // $result->{code} // 502),
        template => 'files/_upload_result',
        layout   => undef,
        success  => $result->{success} ? 1 : 0,
        error    => $result->{error},
        filename => $upload->filename,
    );
}

sub thumbnail ($c) {
    my $file_id = $c->stash('id');
    my $meta    = $c->api->get("/api/v1/drive/files/$file_id/meta");
    return $c->render(data => '', status => 404) unless $meta->{success};

    my $file = $meta->{file};
    my $uuid = $file->{uuid} or return $c->render(data => '', status => 404);
    my ($h1, $h2) = (substr($uuid, 0, 2), substr($uuid, 2, 2));
    my $thumb_path = "/drive-files/.thumbnails/$file->{user_id}/$h1/$h2/$uuid.jpg";

    $c->res->code(200);
    $c->res->headers->content_type('image/jpeg');
    $c->res->headers->header('X-Accel-Redirect' => $thumb_path);
    $c->rendered;
}

sub download ($c) {
    my $file_id    = $c->stash('id');
    my $version_id = $c->param('version');

    # Fetch file metadata (uuid, user_id, name, mime) — no disk I/O
    my $path = "/api/v1/drive/files/$file_id/meta";
    $path .= "?version=$version_id" if $version_id;
    my $meta = $c->api->get($path);

    return $c->render(text => 'File not found', status => 404)
        unless $meta->{success};

    my $file    = $meta->{file};
    my $uuid    = $file->{uuid};
    my $user_id = $file->{user_id};
    my $name    = $file->{file_name};
    my $mime    = $file->{mime_type} // 'application/octet-stream';

    # Build the nginx internal path: /drive-files/{user_id}/{h1}/{h2}/{uuid}
    my $h1 = substr($uuid, 0, 2);
    my $h2 = substr($uuid, 2, 2);
    my $accel_path = "/drive-files/$user_id/$h1/$h2/$uuid";

    # Return headers only — the web server's nginx intercepts X-Accel-Redirect
    # and serves the file directly from NFS. No file data touches this process.
    $c->res->code(200);
    $c->res->headers->content_type($mime);
    $c->res->headers->content_disposition("attachment; filename=\"$name\"");
    $c->res->headers->header('X-Accel-Redirect' => $accel_path);
    $c->rendered;
}

sub zip ($c) {
    my $json     = $c->req->json // {};
    my $result   = $c->api->post('/api/v1/drive/zip', {
        file_ids => $json->{file_ids} // [],
        dir_ids  => $json->{dir_ids}  // [],
        dir_id   => $json->{dir_id},   # destination dir — undef lands at root
    });

    if ($result->{success}) {
        $c->res->headers->header('HX-Trigger' => 'fileListChanged,treeChanged');
        return $c->render(json => { success => 1 }, status => 202);
    }

    $c->render(json => { success => 0, error => $result->{error} // 'Zip failed' }, status => 400);
}

sub delete ($c) {
    my $file_id = $c->stash('id');
    my $result  = $c->api->del("/api/v1/drive/files/$file_id");

    if ($result->{success}) {
        # Return updated row with pending-delete state, or empty to remove the row
        my $tasks = $result->{file}{tasks} // [];
        if (@$tasks) {
            return $c->render(
                template => 'files/_file_row_single',
                layout   => undef,
                file     => $result->{file},
            );
        }
        # No tasks means actually deleted — return empty response so htmx removes the row
        return $c->render(text => '', status => 200);
    }

    $c->render(
        template => 'shared/_error',
        layout   => undef,
        error    => $result->{error} // 'Delete failed',
    );
}

sub update ($c) {
    my $file_id = $c->stash('id');
    my $name    = $c->param('name');
    my $dir_id  = $c->param('dir_id');
    my $to_path = $c->param('to_path');

    my %body;
    $body{name}    = $name    if defined $name    && length $name;
    $body{to_path} = $to_path if defined $to_path && length $to_path;
    if (defined $dir_id) {
        # Numeric = move to specific dir; empty string = move to root (sends JSON null)
        $body{dir_id} = looks_like_number($dir_id) ? $dir_id + 0 : undef;
    }

    my $result = $c->api->patch("/api/v1/drive/files/$file_id", \%body);

    if ($result->{success}) {
        return $c->render(
            template => 'files/_file_row_single',
            layout   => undef,
            file     => $result->{file},
        );
    }

    $c->render(
        template => 'shared/_error',
        layout   => undef,
        error    => $result->{error} // 'Update failed',
    );
}

sub copy ($c) {
    my $file_id = $c->stash('id');
    my $dir_id  = $c->param('dir_id');
    my $to_path = $c->param('to_path');
    my $name    = $c->param('name');

    my %body;
    $body{dir_id}  = $dir_id  if defined $dir_id  && looks_like_number($dir_id);
    $body{to_path} = $to_path if defined $to_path && length $to_path;
    $body{name}    = $name    if defined $name    && length $name;

    my $result = $c->api->post("/api/v1/drive/files/$file_id/copy", \%body);

    if ($result->{success}) {
        $c->res->headers->header('HX-Trigger' => 'fileListChanged');
        return $c->render(text => '', status => 200);
    }

    $c->render(
        template => 'shared/_error',
        layout   => undef,
        error    => $result->{error} // 'Copy failed',
    );
}

sub trash ($c) {
    # Look up the Trash directory ID, then redirect to browse it like any folder
    my $meta = $c->api->get('/api/v1/drive/trash/dir');
    if ($meta->{success}) {
        return $c->redirect_to('/drive?dir_id=' . $meta->{dir_id});
    }
    $c->redirect_to('/drive');
}

sub empty_trash ($c) {
    my $result = $c->api->del('/api/v1/drive/trash');
    if ($result->{success}) {
        return $c->render(json => { success => 1 }, status => 200);
    }
    $c->render(json => { success => 0, error => $result->{error} // 'Failed to empty trash' }, status => 500);
}

sub bulk_restore ($c) {
    my $json     = $c->req->json // {};
    my $result   = $c->api->post('/api/v1/drive/bulk/restore', $json);
    if ($result->{success}) {
        $c->res->headers->header('HX-Trigger' => 'fileListChanged,treeChanged');
        return $c->render(json => { success => 1 }, status => 200);
    }
    $c->render(json => { success => 0, error => $result->{error} // 'Restore failed' }, status => 400);
}

sub restore ($c) {
    my $file_id = $c->stash('id');
    my $result  = $c->api->post("/api/v1/drive/files/$file_id/restore", {});

    if ($result->{success}) {
        $c->res->headers->header('HX-Trigger' => 'fileListChanged');
        return $c->render(text => '', status => 200);
    }

    $c->render(
        template => 'shared/_error',
        layout   => undef,
        error    => $result->{error} // 'Restore failed',
    );
}

# Walk directory parents to build breadcrumb trail.
# Fetches all user directories in one API call, builds an id→dir index, then walks up.
sub _build_breadcrumb ($c, $dir_id) {
    return [] unless defined $dir_id;

    # Fetch all directories (no parent_id param = full list) to walk any parent chain
    my $result = $c->api->get('/api/v1/drive/directories');
    return [] unless $result->{success};

    # Build lookup index
    my %by_id = map { $_->{id} => $_ } @{$result->{directories} // []};

    my @crumbs;
    my $current = $dir_id + 0;
    my $depth   = 0;
    while (defined $current && $depth++ < 50) {
        my $dir = $by_id{$current} or last;
        unshift @crumbs, { id => $dir->{id}, name => $dir->{dir_name} };
        $current = $dir->{parent_id};
    }

    return \@crumbs;
}

1;
