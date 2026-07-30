package Homelab::DriveWebUI::Controller::Directories;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Scalar::Util qw(looks_like_number);

# Directory tree fragment — full recursive listing for the sidebar
sub tree ($c) {
    my $result = $c->api->get('/api/v1/drive/directories');

    if (!$result->{success}) {
        return $c->render(
            template => 'shared/_error',
            layout   => undef,
            error    => $result->{error} // 'Failed to load directories',
        );
    }

    my $dirs   = $result->{directories} // [];
    my $active = $c->param('active_dir_id');
    my $tree   = _build_tree($dirs, undef);

    $c->render(
        template   => 'directories/_dir_tree',
        layout     => undef,
        tree       => $tree,
        active_id  => $active,
    );
}

sub create ($c) {
    my $name      = $c->param('name')      // '';
    my $parent_id = $c->param('parent_id');

    unless (length $name) {
        return $c->render(
            template => 'shared/_error',
            layout   => undef,
            error    => 'Folder name is required',
        );
    }

    my %body = (name => $name);
    $body{parent_id} = $parent_id + 0
        if defined $parent_id && looks_like_number($parent_id);

    my $result = $c->api->post('/api/v1/drive/directories', \%body);

    if ($result->{success}) {
        # Trigger file list and tree refresh
        $c->res->headers->header('HX-Trigger' => 'fileListChanged,treeChanged');
        return $c->render(text => '', status => 201);
    }

    $c->render(
        template => 'shared/_error',
        layout   => undef,
        error    => $result->{error} // 'Failed to create folder',
    );
}

sub delete ($c) {
    my $dir_id = $c->stash('id');
    my $result = $c->api->del("/api/v1/drive/directories/$dir_id");

    if ($result->{success}) {
        $c->res->headers->header('HX-Trigger' => 'fileListChanged,treeChanged');
        return $c->render(text => '', status => 200);
    }

    $c->render(
        template => 'shared/_error',
        layout   => undef,
        error    => $result->{error} // 'Failed to delete folder',
    );
}

# Flat JSON tree for jsTree — returns [{id, parent, text}, ...] sorted by text
sub tree_json ($c) {
    my $result = $c->api->get('/api/v1/drive/directories');
    return $c->render(json => []) unless $result->{success};

    my @nodes = sort { $a->{text} cmp $b->{text} }
                map {
                    {
                        id     => "$_->{id}",
                        parent => defined $_->{parent_id} ? "$_->{parent_id}" : '#',
                        text   => $_->{dir_name},
                    }
                } @{$result->{directories} // []};

    $c->render(json => \@nodes);
}

sub update ($c) {
    my $dir_id    = $c->stash('id');
    my $name      = $c->param('name');
    my $parent_id = $c->param('parent_id');

    my %body;
    if (defined $name && length $name) {
        $body{name} = $name;
    } elsif (defined $parent_id) {
        $body{parent_id} = looks_like_number($parent_id) ? $parent_id + 0 : undef;
    } else {
        return $c->render(json => { success => 0, error => 'name or parent_id required' }, status => 400);
    }

    my $result = $c->api->patch("/api/v1/drive/directories/$dir_id", \%body);

    if ($result->{success}) {
        my $trigger = exists $body{parent_id} ? 'treeChanged,fileListChanged' : 'treeChanged';
        $c->res->headers->header('HX-Trigger' => $trigger);
        return $c->render(json => { success => 1 }, status => 200);
    }

    $c->render(json => { success => 0, error => $result->{error} // 'Failed to update folder' }, status => 400);
}

sub bulk_trash ($c) {
    my $json    = $c->req->json // {};
    my $result  = $c->api->post('/api/v1/drive/bulk/trash', $json);
    if ($result->{success}) {
        $c->res->headers->header('HX-Trigger' => 'fileListChanged,treeChanged');
        return $c->render(json => { success => 1, trash_dir_id => $result->{trash_dir_id} }, status => 200);
    }
    $c->render(json => { success => 0, error => $result->{error} // 'Bulk trash failed' }, status => 400);
}

sub bulk_move ($c) {
    my $json   = $c->req->json // {};
    my $result = $c->api->post('/api/v1/drive/bulk/move', $json);
    if ($result->{success}) {
        $c->res->headers->header('HX-Trigger' => 'fileListChanged,treeChanged');
        # Pass moved/skipped lists through so the UI can show per-file results
        return $c->render(json => {
            success => 1,
            moved   => $result->{moved}   // [],
            skipped => $result->{skipped} // [],
        }, status => 200);
    }
    $c->render(json => { success => 0, error => $result->{error} // 'Bulk move failed' }, status => 400);
}

sub bulk_copy ($c) {
    my $json   = $c->req->json // {};
    my $result = $c->api->post('/api/v1/drive/bulk/copy', $json);
    if ($result->{success}) {
        $c->res->headers->header('HX-Trigger' => 'fileListChanged,treeChanged');
        return $c->render(json => {
            success => 1,
            queued  => $result->{queued}  // [],
            skipped => $result->{skipped} // [],
        }, status => 200);
    }
    $c->render(json => { success => 0, error => $result->{error} // 'Bulk copy failed' }, status => 400);
}

# Build nested tree structure from flat directory list
sub _build_tree ($dirs, $parent_id) {
    my @nodes;
    for my $d (@$dirs) {
        my $dp = $d->{parent_id};
        my $matches = defined $parent_id
            ? (defined $dp && $dp == $parent_id)
            : !defined $dp;
        next unless $matches;

        push @nodes, {
            id       => $d->{id},
            name     => $d->{dir_name},
            children => _build_tree($dirs, $d->{id}),
        };
    }
    return [sort { $a->{name} cmp $b->{name} } @nodes];
}

1;
