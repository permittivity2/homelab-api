#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'HOMELAB_API_CONFIG not set; skipping integration tests';
}

require Test::Mojo;

my $t = Test::Mojo->new('Homelab::API');

# Get a test token first
my $login = $t->post_ok('/api/v1/auth/login',
    json => { email => 'permittivity@example.com', password => 'Mcl532vtc896?.' })
    ->status_is(200)
    ->json_is('/success', 1);

my $token = $login->tx->res->json->{token};
ok($token, 'Got JWT token');

subtest 'drive quota' => sub {
    $t->get_ok('/api/v1/drive/quota',
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1);

    my $quota = $t->tx->res->json->{quota};
    ok(defined $quota->{used_bytes}, 'has used_bytes');
    ok(defined $quota->{limit_bytes}, 'has limit_bytes');
};

subtest 'create directory' => sub {
    $t->post_ok('/api/v1/drive/directories',
        { Authorization => "Bearer $token" },
        json => { name => 'TestDir' })
        ->status_is(201)
        ->json_is('/success', 1);

    my $dir_id = $t->tx->res->json->{directory}{id};
    ok($dir_id, 'directory created with id');

    # List directories
    $t->get_ok('/api/v1/drive/directories',
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1);

    my $dirs = $t->tx->res->json->{directories};
    ok(scalar(@$dirs) > 0, 'directory appears in list');
};

subtest 'upload and list files' => sub {
    my $content = "Test file content\n";

    $t->post_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" },
        form => { file => { content => $content, filename => 'test.txt' } })
        ->status_is(201)
        ->json_is('/success', 1);

    my $file = $t->tx->res->json->{file};
    ok($file->{id}, 'file created with id');
    ok($file->{version}{uuid}, 'version has uuid');
    ok($file->{version}{sha256}, 'version has sha256');

    # List files
    $t->get_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1);

    my $files = $t->tx->res->json->{files};
    ok(scalar(@$files) > 0, 'file appears in list');
};

subtest 'reject empty upload' => sub {
    $t->post_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" },
        form => { file => { content => '', filename => 'empty.mp4' } })
        ->status_is(400);

    like($t->tx->res->json->{error}, qr/empty/i, 'error mentions empty file');
};

subtest 'download file' => sub {
    # First create a file
    $t->post_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" },
        form => { file => { content => "Download test\n", filename => 'download.txt' } })
        ->status_is(201);

    my $file_id = $t->tx->res->json->{file}{id};

    # Download it
    $t->get_ok("/api/v1/drive/files/$file_id",
        { Authorization => "Bearer $token" })
        ->status_is(200);

    ok($t->tx->res->body, 'response has body');
};

subtest 'soft delete and restore' => sub {
    # Create file
    $t->post_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" },
        form => { file => { content => "Delete test\n", filename => 'delete.txt' } })
        ->status_is(201);

    my $file_id = $t->tx->res->json->{file}{id};

    # Delete it
    $t->delete_ok("/api/v1/drive/files/$file_id",
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1);

    # List trash
    $t->get_ok('/api/v1/drive/trash',
        { Authorization => "Bearer $token" })
        ->status_is(200);

    my $trash = $t->tx->res->json->{files};
    ok(scalar(@$trash) > 0, 'deleted file appears in trash');

    # Restore it
    $t->post_ok("/api/v1/drive/files/$file_id/restore",
        { Authorization => "Bearer $token" })
        ->status_is(200)
        ->json_is('/success', 1);

    # Verify it's back in list
    $t->get_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" })
        ->status_is(200);

    my $files = $t->tx->res->json->{files};
    ok(scalar(grep { $_->{id} == $file_id } @$files) > 0, 'restored file in list');
};

subtest 'list versions' => sub {
    # Create file
    $t->post_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" },
        form => { file => { content => "Version 1\n", filename => 'versions.txt' } })
        ->status_is(201);

    my $file_id = $t->tx->res->json->{file}{id};

    # Upload again (new version)
    $t->post_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" },
        form => { file => { content => "Version 2\n", filename => 'versions.txt' } })
        ->status_is(201);

    # List versions
    $t->get_ok("/api/v1/drive/files/$file_id/versions",
        { Authorization => "Bearer $token" })
        ->status_is(200);

    my $versions = $t->tx->res->json->{versions};
    ok(scalar(@$versions) >= 1, 'versions listed');
};

subtest 'create and list shares' => sub {
    # Create file
    $t->post_ok('/api/v1/drive/files',
        { Authorization => "Bearer $token" },
        form => { file => { content => "Share test\n", filename => 'share.txt' } })
        ->status_is(201);

    my $file_id = $t->tx->res->json->{file}{id};

    # Create share
    $t->post_ok("/api/v1/drive/files/$file_id/share",
        { Authorization => "Bearer $token" },
        json => { permission => 'read' })
        ->status_is(201)
        ->json_is('/success', 1);

    my $share_token = $t->tx->res->json->{share}{share_token};
    ok($share_token, 'share has token');

    # List shares
    $t->get_ok('/api/v1/drive/shares',
        { Authorization => "Bearer $token" })
        ->status_is(200);

    my $shares = $t->tx->res->json->{shares};
    ok(scalar(@$shares) > 0, 'share appears in list');

    # Access public share
    $t->get_ok("/api/v1/drive/s/$share_token")
        ->status_is(200);

    ok($t->tx->res->body, 'public share returns file content');
};

done_testing;
