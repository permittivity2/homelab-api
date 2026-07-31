package Homelab::DriveWebUI::Controller::Sharing;

use Mojo::Base 'Mojolicious::Controller', -signatures;

# POST /drive/files/:id/share
sub share_file ($c) {
    my $json   = $c->req->json // {};
    my $result = $c->api->post("/api/v1/drive/files/" . $c->stash('id') . "/share", {
        share_with => $json->{share_with},
        permission => $json->{permission} // 'read',
    });
    my $status = $result->{success} ? 201 : 400;
    $c->render(json => $result, status => $status);
}

# POST /drive/directories/:id/share
sub share_dir ($c) {
    my $json   = $c->req->json // {};
    my $result = $c->api->post("/api/v1/drive/directories/" . $c->stash('id') . "/share", {
        share_with => $json->{share_with},
        permission => $json->{permission} // 'read',
    });
    my $status = $result->{success} ? 201 : 400;
    $c->render(json => $result, status => $status);
}

# GET /drive/shares  (my outgoing shares)
sub list_my_shares ($c) {
    my $result = $c->api->get('/api/v1/drive/shares');
    $c->render(json => $result, status => $result->{error} ? 400 : 200);
}

# DELETE /drive/shares/:id
sub revoke ($c) {
    my $result = $c->api->del('/api/v1/drive/shares/' . $c->stash('id'));
    $c->render(json => $result, status => $result->{error} ? 404 : 200);
}

# GET /drive/shared-with-me  — page showing files/dirs others shared with me
sub shares_with_me ($c) {
    my $result = $c->api->get('/api/v1/drive/shares/with-me');
    $c->stash(shares => $result->{shares} // []);
    $c->render(template => 'sharing/shared_with_me', layout => 'default');
}

# GET /s/:token  — public share landing page (no auth required)
sub public_view ($c) {
    my $token = $c->stash('token');

    # Try file share first
    my $file_meta = $c->api->get("/api/v1/drive/s/$token/meta");
    if ($file_meta->{success}) {
        $c->stash(
            share_type => 'file',
            token      => $token,
            file_name  => $file_meta->{file_name},
            file_size  => $file_meta->{file_size},
            mime_type  => $file_meta->{mime_type},
        );
        return $c->render(template => 'sharing/public', layout => 'public');
    }

    # Try dir share
    my $dir_meta = $c->api->get("/api/v1/drive/s/$token/dir");
    if ($dir_meta->{success}) {
        $c->stash(
            share_type  => 'dir',
            token       => $token,
            dir_name    => $dir_meta->{dir_name},
            owner_email => $dir_meta->{owner_email},
            files       => $dir_meta->{files} // [],
        );
        return $c->render(template => 'sharing/public', layout => 'public');
    }

    $c->render(template => 'sharing/public_not_found', layout => 'public', status => 404);
}

# GET /s/:token/download  — X-Accel-Redirect file download for public shares
sub public_download ($c) {
    my $token  = $c->stash('token');
    my $meta   = $c->api->get("/api/v1/drive/s/$token/meta");

    return $c->render(text => 'Share not found', status => 404) unless $meta->{success};

    my $uuid    = $meta->{uuid};
    my $user_id = $meta->{user_id};
    my $h1      = substr($uuid, 0, 2);
    my $h2      = substr($uuid, 2, 2);

    $c->res->code(200);
    $c->res->headers->content_type($meta->{mime_type} // 'application/octet-stream');
    $c->res->headers->content_disposition("attachment; filename=\"$meta->{file_name}\"");
    $c->res->headers->header('X-Accel-Redirect' => "/drive-files/$user_id/$h1/$h2/$uuid");
    $c->rendered;
}

# GET /s/:token/thumbnail — inline thumbnail for a public single-file share
sub public_thumbnail ($c) {
    my $token = $c->stash('token');
    my $meta  = $c->api->get("/api/v1/drive/s/$token/meta");
    return $c->render(data => '', status => 404) unless $meta->{success};

    my ($h1, $h2) = (substr($meta->{uuid}, 0, 2), substr($meta->{uuid}, 2, 2));
    $c->res->code(200);
    $c->res->headers->content_type('image/jpeg');
    $c->res->headers->header('X-Accel-Redirect' =>
        "/drive-files/.thumbnails/$meta->{user_id}/$h1/$h2/$meta->{uuid}.jpg");
    $c->rendered;
}

# GET /s/:token/slide-show-image — inline slideshow-sized image for a public single-file share
sub public_slide_show_image ($c) {
    my $token = $c->stash('token');
    my $meta  = $c->api->get("/api/v1/drive/s/$token/meta");
    return $c->render(data => '', status => 404) unless $meta->{success};

    my ($h1, $h2) = (substr($meta->{uuid}, 0, 2), substr($meta->{uuid}, 2, 2));
    $c->res->code(200);
    $c->res->headers->content_type('image/jpeg');
    $c->res->headers->header('X-Accel-Redirect' =>
        "/drive-files/.slide_show_images/$meta->{user_id}/$h1/$h2/$meta->{uuid}.jpg");
    $c->rendered;
}

# GET /s/:token/files/:file_uuid/download — download a file from a shared dir
sub public_dir_file_download ($c) {
    my $token     = $c->stash('token');
    my $file_uuid = $c->stash('file_uuid');

    # Validate the dir share token, then find the file in it
    my $dir_meta = $c->api->get("/api/v1/drive/s/$token/dir");
    return $c->render(text => 'Share not found', status => 404) unless $dir_meta->{success};

    my ($file) = grep { $_->{uuid} eq $file_uuid } @{$dir_meta->{files} // []};
    return $c->render(text => 'File not found in share', status => 404) unless $file;

    my $h1 = substr($file_uuid, 0, 2);
    my $h2 = substr($file_uuid, 2, 2);

    $c->res->code(200);
    $c->res->headers->content_type($file->{mime_type} // 'application/octet-stream');
    $c->res->headers->content_disposition("attachment; filename=\"$file->{file_name}\"");
    $c->res->headers->header('X-Accel-Redirect' => "/drive-files/$file->{owner_user_id}/$h1/$h2/$file_uuid");
    $c->rendered;
}

# GET /s/:token/files/:file_uuid/thumbnail — inline thumbnail for a file in a shared dir
sub public_dir_file_thumbnail ($c) {
    my $token     = $c->stash('token');
    my $file_uuid = $c->stash('file_uuid');
    my $dir_meta  = $c->api->get("/api/v1/drive/s/$token/dir");
    return $c->render(data => '', status => 404) unless $dir_meta->{success};

    my ($file) = grep { $_->{uuid} eq $file_uuid } @{$dir_meta->{files} // []};
    return $c->render(data => '', status => 404) unless $file;

    my ($h1, $h2) = (substr($file_uuid, 0, 2), substr($file_uuid, 2, 2));
    $c->res->code(200);
    $c->res->headers->content_type('image/jpeg');
    $c->res->headers->header('X-Accel-Redirect' =>
        "/drive-files/.thumbnails/$file->{owner_user_id}/$h1/$h2/$file_uuid.jpg");
    $c->rendered;
}

# GET /s/:token/files/:file_uuid/slide-show-image — inline slideshow-sized image for a file in a shared dir
sub public_dir_file_slide_show_image ($c) {
    my $token     = $c->stash('token');
    my $file_uuid = $c->stash('file_uuid');
    my $dir_meta  = $c->api->get("/api/v1/drive/s/$token/dir");
    return $c->render(data => '', status => 404) unless $dir_meta->{success};

    my ($file) = grep { $_->{uuid} eq $file_uuid } @{$dir_meta->{files} // []};
    return $c->render(data => '', status => 404) unless $file;

    my ($h1, $h2) = (substr($file_uuid, 0, 2), substr($file_uuid, 2, 2));
    $c->res->code(200);
    $c->res->headers->content_type('image/jpeg');
    $c->res->headers->header('X-Accel-Redirect' =>
        "/drive-files/.slide_show_images/$file->{owner_user_id}/$h1/$h2/$file_uuid.jpg");
    $c->rendered;
}

1;
